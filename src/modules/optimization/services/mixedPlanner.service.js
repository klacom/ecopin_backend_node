import { supabaseAdmin as db } from '../../../config/supabase.config.js';
import { prioritizeBacklog } from './workQueue.service.js';
import { reportPriority, selectPlanItems, resolvePlanSettings } from './planningPolicy.js';
import { groupClustersForTask } from './taskGrouping.js';
import { bundleReports, defaultReportVolume, defaultReportWeight, defaultCrewVolumeCapacity, defaultCrewWeightCapacity } from './bundler.js';
import { metresBetween, provisionalAnchorSuccessors } from './geoTime.js';
import { getTomTomDistanceMatrix } from '../providers/tomtom.provider.js';
import { solveVRPWithOrTools } from './ortools.service.js';
import { getLiveWeatherCondition } from './weather.service.js';

async function rows(query) { const { data, error } = await query; if (error) throw error; return data ?? []; }
function point(row) { return { lat: Number(row.lat), lng: Number(row.lng) }; }
function clockMinutes(value) { const [h, m] = String(value).split(':').map(Number); return h * 60 + m; }
function amount(value) { return value == null ? null : Number(value); }
function crewCapacity(crew, settings) {
  const start = clockMinutes(crew.shift_start), end = clockMinutes(crew.shift_end);
  return Math.max(0, (end >= start ? end - start : end + 1440 - start)
    - settings.break_duration_min + settings.overtime_tolerance_min);
}

function buildVehicles(crews, depot, settings, activeTasks = []) {
  return crews.filter(crew => crew.shift_start && crew.shift_end && (crew.supports_standard || crew.supports_sweeper))
    .map(crew => {
      const members = [...(crew.member_profile_ids ?? []), crew.team_lead_profile_id].filter(Boolean);
      const busy = activeTasks.filter(task =>
        !['completed', 'cancelled'].includes(task.status) &&
        (task.assigned_field_crew_id === crew.id || task.assigned_crew_ids?.some(id => members.includes(id)))
      );
      const busyCount = busy.length;
      const busyMinutes = busy.reduce((sum, task) => sum + Number(task.estimated_duration_min ?? 60), 0);
      const busyVolume = busy.reduce((sum, task) => sum + Number(task.estimated_volume_m3 ?? 0.1), 0);
      const busyWeight = busy.reduce((sum, task) => sum + Number(task.estimated_weight_kg ?? 10), 0);

      const start = clockMinutes(crew.shift_start);
      let end = clockMinutes(crew.shift_end);
      if (end <= start) end += 1440;
      const shiftMinutes = end - start;
      const totalBudget = Math.max(0, (shiftMinutes - settings.break_duration_min + settings.overtime_tolerance_min) * settings.capacity_utilization);
      const remainingBudget = Math.max(0, totalBudget - busyMinutes);

      const maxTasksAllowed = Math.min(crew.max_tasks_per_shift ?? 10, settings.max_tasks_per_shift);
      const remainingTasks = Math.max(0, maxTasksAllowed - busyCount);

      const maxVol = amount(crew.max_volume_m3) ?? defaultCrewVolumeCapacity(crew);
      const maxWt = amount(crew.max_weight_kg) ?? defaultCrewWeightCapacity(crew);
      const startingVol = Math.min(maxVol, (amount(crew.starting_volume_m3) ?? 0) + busyVolume);
      const startingWt = Math.min(maxWt, (amount(crew.starting_weight_kg) ?? 0) + busyWeight);

      // Reserve 15 minutes for per-leg ceiling rounding and transit variance
      const ROUTING_ROUNDING_BUFFER_MIN = 15;
      const effectiveBudget = Math.max(0, remainingBudget - ROUTING_ROUNDING_BUFFER_MIN);
      const constrainedEnd = start + settings.break_duration_min + Math.floor(effectiveBudget);

      return {
        id: crew.id,
        depot,
        shift_start_min: start,
        shift_end_min: constrainedEnd,
        break_min: settings.break_duration_min,
        max_tasks: remainingTasks,
        remaining_budget_min: remainingBudget,
        effective_budget_min: effectiveBudget,
        speed_factor: Number(crew.speed_factor),
        service_time_factor: Number(crew.service_time_factor),
        max_volume_m3: maxVol,
        max_weight_kg: maxWt,
        starting_volume_m3: startingVol,
        starting_weight_kg: startingWt,
        certifications: crew.certifications ?? [],
        hazmat_certified: crew.hazmat_certified === true,
        supports_standard: crew.supports_standard,
        allowed_task_types: [
          crew.supports_standard && 'Standard',
          crew.supports_standard && 'Satellite',
          crew.supports_sweeper && 'Sweeper'
        ].filter(Boolean)
      };
    })
    .filter(vehicle => vehicle.max_tasks > 0 && vehicle.effective_budget_min > 0);
}

export function validateMixedProposal(proposal, tasks, matrix, vehicles, settings) {
  if (proposal.status !== 'success') throw new Error('Solver returned no feasible route');
  const byId = new Map(tasks.map(task => [task.id, task]));
  const node = new Map(tasks.map((task, i) => [task.id, vehicles.length + i]));
  const seen = new Set();
  const violations = [];
  const assignments = new Map(proposal.routes.flatMap(route => route.stops.map(stop => [stop.task_id, route.vehicle_id])));
  for (const task of tasks.filter(task => task.anchor_id && assignments.has(task.id))) {
    if (assignments.get(task.anchor_id) !== assignments.get(task.id))
      throw new Error('Solver split a satellite from its anchor');
  }
  for (const route of proposal.routes) {
    const vehicleIndex = vehicles.findIndex(vehicle => vehicle.id === route.vehicle_id);
    if (vehicleIndex < 0) throw new Error('Solver returned an unknown vehicle');
    const stops = route.stops.map(stop => {
      if (!byId.has(stop.task_id) || seen.has(stop.task_id)) throw new Error('Solver duplicated or invented a stop');
      seen.add(stop.task_id);
      return byId.get(stop.task_id);
    });
    for (const anchor of stops.filter(task => task.task_type === 'Standard')) {
      const at = stops.indexOf(anchor);
      const satelliteStops = stops.filter(task => task.anchor_id === anchor.id);
      if (!satelliteStops.length) continue;
      const satelliteIndexes = satelliteStops.map(task => stops.indexOf(task));
      if (satelliteIndexes.some(index => index <= at)) throw new Error('Solver violated anchor precedence');
      const routeNodes = [vehicleIndex, ...stops.map(task => node.get(task.id)), vehicleIndex];
      const removed = new Set(satelliteStops.map(task => node.get(task.id)));
      const directNodes = routeNodes.filter(index => !removed.has(index));
      const routeCost = nodes => nodes.slice(1).reduce((sum, index, position) =>
        sum + matrix[nodes[position]][index], 0);
      const detour = Math.max(0, routeCost(routeNodes) - routeCost(directNodes)) /
        Number(vehicles[vehicleIndex].speed_factor);
      if (detour > settings.mixed_max_detour_minutes + 1e-6) {
        violations.push({ group_key: anchor.group_key, reason: 'detour_cap_unenforceable', detour_minutes: detour });
      }
    }
  }
  for (const task of tasks) {
    if (!seen.has(task.id) && !proposal.unassigned.some(item => item.task_id === task.id))
      throw new Error('Solver omitted a task without an unassigned diagnostic');
  }
  return violations;
}

export async function generateMixedDispatchPlan(actor, input, { jobId, workerToken }) {
  const weatherCondition = input?.weather_condition ?? (process.env.NODE_ENV === 'test' ? 'normal' : await getLiveWeatherCondition().catch(() => 'normal'));
  await prioritizeBacklog(weatherCondition === 'severe' ? 'storm' : weatherCondition === 'rainy' ? 'heavy_rain' : 'normal');
  const weatherMultiplier = weatherCondition === 'severe' ? 1.30 : weatherCondition === 'rainy' ? 1.15 : 1.0;
  const [settingRows, snapshot, availableCrews, activeTasks] = await Promise.all([
    rows(db.from('optimization_settings').select('key,value')),
    rows(db.rpc('mixed_planning_snapshot')),
    rows(db.from('field_crews').select('*').eq('availability_status', 'available')),
    rows(db.from('cleanup_tasks').select('assigned_field_crew_id,assigned_crew_ids,status,estimated_duration_min,estimated_volume_m3,estimated_weight_kg')
      .not('status', 'in', '(completed,cancelled)'))
  ]);
  const crews = availableCrews.filter(crew =>
    (crew.member_profile_ids?.length ?? 0) > 0 || crew.team_lead_profile_id);
  const configured = Object.fromEntries(settingRows.map(row => [row.key, row.value]));
  const settings = { ...configured, ...resolvePlanSettings(input), mode: 'mixed', weather_condition: weatherCondition, weather_multiplier: weatherMultiplier };
  for (const key of ['mixed_spatial_buffer_meters','mixed_max_reports_per_anchor','mixed_max_detour_minutes',
    'solver_time_limit_seconds','solver_max_candidate_nodes','mixed_bundle_reserve_pct']) settings[key] = Number(settings[key]);
  if (!Number.isInteger(settings.solver_max_candidate_nodes) || settings.solver_max_candidate_nodes < 1 ||
      settings.solver_max_candidate_nodes > 200 ||
      !Number.isFinite(settings.solver_time_limit_seconds) || settings.solver_time_limit_seconds < 2 ||
      settings.solver_time_limit_seconds > 60 ||
      !Number.isFinite(settings.mixed_spatial_buffer_meters) || settings.mixed_spatial_buffer_meters < 100 ||
      settings.mixed_spatial_buffer_meters > 5000 ||
      !Number.isInteger(settings.mixed_max_reports_per_anchor) || settings.mixed_max_reports_per_anchor < 0 ||
      settings.mixed_max_reports_per_anchor > 5 ||
      !Number.isFinite(settings.mixed_max_detour_minutes) || settings.mixed_max_detour_minutes < 0 ||
      settings.mixed_max_detour_minutes > 120 ||
      !Number.isFinite(settings.mixed_bundle_reserve_pct) || settings.mixed_bundle_reserve_pct < 0 ||
      settings.mixed_bundle_reserve_pct > 50)
    throw new Error('Invalid Mixed planning bounds');
  const depotValue = configured.swmo_depot;
  const depot = { lat: Number(depotValue?.latitude), lng: Number(depotValue?.longitude) };
  if (![depot.lat, depot.lng].every(Number.isFinite)) throw new Error('Configure swmo_depot before Mixed planning');
  settings.depot = depot;
  const anchors = groupClustersForTask(snapshot.anchors.map(row => ({ id: row.id, centre: point(row),
    created_at: row.created_at, priority_score: Number(row.priority_score ?? 0),
    reportIds: row.report_ids, effortMinutes: Math.max(1, Math.ceil(Number(row.estimated_effort_minutes ?? 60) * weatherMultiplier)),
    estimated_volume_m3: amount(row.estimated_volume_m3) ?? defaultReportVolume(row),
    estimated_weight_kg: amount(row.estimated_weight_kg) ?? defaultReportWeight(row) })));
  const candidates = anchors.map(group => ({ item_type: 'cluster', cluster_id: group.members[0].id,
    cluster_ids: group.clusterIds, report_id: null, group_key: group.group_key,
    report_ids: group.reportIds, centre: group.centre,
    service_minutes: Math.max(1, group.effortMinutes), priority_score: group.priority,
    estimated_volume_m3: group.members.reduce((sum, member) => sum + (amount(member.estimated_volume_m3) ?? defaultReportVolume(member)), 0),
    estimated_weight_kg: group.members.reduce((sum, member) => sum + (amount(member.estimated_weight_kg) ?? defaultReportWeight(member)), 0) }));
  const generalists = crews.filter(crew => crew.supports_standard);
  const anchorSelection = selectPlanItems(candidates, generalists, activeTasks, {
    ...settings, capacity_utilization: settings.capacity_utilization * (1 - settings.mixed_bundle_reserve_pct / 100) });
  const crewById = new Map(crews.map(crew => [crew.id, crew]));
  const selectedGroups = anchorSelection.items.filter(item => item.is_selected).map(item => ({
    ...item, crew: crewById.get(item.planned_crew_id),
    estimated_volume_m3: item.estimated_volume_m3, estimated_weight_kg: item.estimated_weight_kg }));
  const successors = provisionalAnchorSuccessors(selectedGroups, depot);
  for (const group of selectedGroups) group.successorCentre = successors.get(group.group_key);
  const reports = snapshot.satellites.map(row => ({ ...row, location: point(row),
    estimated_volume_m3: amount(row.estimated_volume_m3) ?? defaultReportVolume(row),
    estimated_weight_kg: amount(row.estimated_weight_kg) ?? defaultReportWeight(row),
    base_priority_score: reportPriority(row, settings.mcda_weights), workMinutes: Math.max(1, Math.ceil(Number(row.work_time_minutes ?? 30) * weatherMultiplier)) }));
  const reserve = Math.floor(generalists.reduce((sum, crew) => sum + crewCapacity(crew, settings), 0)
    * settings.mixed_bundle_reserve_pct / 100);
  const bundles = bundleReports({ groups: selectedGroups, candidates: reports, settings,
    workMinutes: report => report.workMinutes, remainingMinutes: reserve });
  const reportById = new Map(reports.map(report => [report.id, report]));
  const anchorByKey = new Map(anchorSelection.items.map(item => [item.group_key, item]));
  const tasks = anchorSelection.items.filter(item => item.is_selected).map(item => ({ id: item.group_key,
    group_key: item.group_key, task_type: 'Standard', location: item.centre, service_minutes: item.service_minutes,
    estimated_volume_m3: item.estimated_volume_m3, estimated_weight_kg: item.estimated_weight_kg,
    required_certifications: [], drop_penalty: 100000 + Math.round(item.priority_score * 100) }));
  for (const bundle of bundles.assignments) for (const { report } of bundle.satellites) tasks.push({
    id: `satellite:${report.id}`, group_key: bundle.group_key, anchor_id: bundle.group_key,
    bundle_group_key: bundle.group_key, task_type: 'Satellite', location: report.location,
    service_minutes: report.workMinutes, estimated_volume_m3: report.estimated_volume_m3,
    estimated_weight_kg: report.estimated_weight_kg, required_certifications: [],
    drop_penalty: 10000 + Math.round(report.base_priority_score * 100) });
  const bundledIds = new Set(bundles.assignments.flatMap(bundle => bundle.satellites.map(item => item.report.id)));
  const outsideBuffer = new Set(bundles.rejected.filter(item => item.reason === 'outside_buffer')
    .map(item => item.report_id));
  const standalone = reports.filter(report => report.lifecycle_state === 'sla_breached' && !report.blocked &&
    outsideBuffer.has(report.id) &&
    !bundledIds.has(report.id) && settings.mixed_include_standalone_breached !== false &&
    !['suspected_hazard','hazmat_required','hazard_review'].includes(report.hazard_class));
  for (const report of standalone.slice(0, Math.max(0, settings.solver_max_candidate_nodes - tasks.length))) {
    tasks.push({ id: `sweeper:${report.id}`, group_key: `sweeper:${report.id}`, task_type: 'Sweeper',
      location: report.location, service_minutes: report.workMinutes,
      estimated_volume_m3: report.estimated_volume_m3 ?? defaultReportVolume(report),
      estimated_weight_kg: report.estimated_weight_kg ?? defaultReportWeight(report),
      required_certifications: [], drop_penalty: 50000 + Math.round(report.base_priority_score * 100) });
  }
  // Release only the reserve left after bundling. Existing anchors and satellites consume
  // their assigned crews' budgets before another cluster can enter this same solve.
  const reservedWork = anchorSelection.items.filter(item => item.is_selected).map(item => ({
    status: 'assigned', assigned_field_crew_id: item.planned_crew_id,
    estimated_duration_min: item.estimated_duration_minutes }));
  const satelliteWork = bundles.assignments.flatMap(bundle => bundle.satellites.map(({ report, provisionalDetourMinutes }) => ({
    status: 'assigned', assigned_field_crew_id: selectedGroups.find(group => group.group_key === bundle.group_key)?.planned_crew_id,
    estimated_duration_min: Math.ceil(report.workMinutes + provisionalDetourMinutes) })));
  const remainingSlots = Math.max(0, settings.solver_max_candidate_nodes - tasks.length);
  const topUp = remainingSlots ? selectPlanItems(anchorSelection.items.filter(item => !item.is_selected).slice(0, remainingSlots),
    generalists, [...activeTasks, ...reservedWork, ...satelliteWork], settings) : { items: [] };
  const topUpByKey = new Map(topUp.items.map(item => [item.group_key, item]));
  const allAnchorItems = anchorSelection.items.map(item => topUpByKey.get(item.group_key)?.is_selected
    ? topUpByKey.get(item.group_key) : item);
  for (const item of topUp.items.filter(item => item.is_selected)) tasks.push({
    id: item.group_key, group_key: item.group_key, task_type: 'Standard', location: item.centre,
    service_minutes: item.service_minutes, estimated_volume_m3: item.estimated_volume_m3,
    estimated_weight_kg: item.estimated_weight_kg, required_certifications: [],
    drop_penalty: 100000 + Math.round(item.priority_score * 100) });
  const vehicles = buildVehicles(crews, depot, settings, activeTasks);
  if (!vehicles.length) throw new Error('No capable crews are available');
  const points = [...vehicles.map(vehicle => vehicle.depot), ...tasks.map(task => task.location)];
  let travelSeconds;
  let matrixFallbackUsed = false;
  if (!tasks.length) {
    travelSeconds = points.map(() => points.map(() => 0));
  } else {
    try {
      travelSeconds = await getTomTomDistanceMatrix(points);
    } catch (err) {
      console.warn('[MixedPlanner] TomTom Distance Matrix unavailable, using resilient geometric matrix fallback:', err.message);
      matrixFallbackUsed = true;
      const speedMps = ({ DRIVING: 500 / 60, MOTORCYCLE: 580 / 60, BICYCLE: 250 / 60, WALKING: 80 / 60 }[settings.travel_mode] ?? (500 / 60));
      const circuity = settings.planning_circuity_factor ?? 1.35;
      travelSeconds = points.map(a => points.map(b => (metresBetween(a, b) * circuity) / speedMps));
    }
  }
  const travel = travelSeconds.map(row => row.map(seconds => seconds / 60));
  const distance = points.map(a => points.map(b => metresBetween(a, b)));
  const payload = { contract_version: 'v5', vehicles, tasks, travel_time_matrix_min: travel,
    distance_matrix_m: distance, options: { solver_time_limit_seconds: settings.solver_time_limit_seconds,
      max_candidate_nodes: settings.solver_max_candidate_nodes } };
  const proposal = tasks.length ? await solveVRPWithOrTools(payload) :
    { contract_version: 'v5', status: 'success', routes: vehicles.map(vehicle => ({ vehicle_id: vehicle.id, stops: [] })),
      unassigned: [], solver_diagnostics: { candidate_nodes: 0 } };
  const violations = validateMixedProposal(proposal, tasks, travel, vehicles, settings);
  const assigned = new Map(proposal.routes.flatMap(route => route.stops.map((stop, order) =>
    [stop.task_id, { crewId: route.vehicle_id, order, load: { volume_m3: stop.volume_after_m3,
      weight_kg: stop.weight_after_kg } }])));
  const unassigned = new Map(proposal.unassigned.map(item => [item.task_id, item.reason]));
  const rejected = [
    ...bundles.rejected.filter(entry => entry.reason !== 'outside_buffer' ||
      !assigned.has(`sweeper:${entry.report_id}`)),
    ...proposal.unassigned.map(entry => ({ task_id: entry.task_id,
      report_id: entry.task_id.startsWith('satellite:') || entry.task_id.startsWith('sweeper:')
        ? entry.task_id.slice(entry.task_id.indexOf(':') + 1) : undefined,
      group_key: entry.task_id.startsWith('cluster:') ? entry.task_id : undefined,
      reason: entry.reason })),
    ...violations
  ];
  const unusableGroups = new Set(violations.map(item => item.group_key));
  const items = allAnchorItems.map(item => {
    const isSelected = assigned.has(item.group_key) && !unusableGroups.has(item.group_key);
    return {
      ...item,
      is_selected: isSelected,
      status: isSelected ? 'scheduled' : 'backlog',
      operational_label: isSelected ? 'Scheduled for dispatch' : 'Queued in backlog for next shift',
      planned_crew_id: assigned.get(item.group_key)?.crewId ?? null,
      reason: unusableGroups.has(item.group_key) ? 'detour_cap_unenforceable' :
        unassigned.get(item.group_key) ?? item.reason,
      estimated_volume_m3: item.estimated_volume_m3, estimated_weight_kg: item.estimated_weight_kg,
      load_snapshot: assigned.get(item.group_key)?.load ?? null,
      crew_snapshot: assigned.get(item.group_key) ? {
        speed_factor: Number(crewById.get(assigned.get(item.group_key).crewId).speed_factor),
        service_time_factor: Number(crewById.get(assigned.get(item.group_key).crewId).service_time_factor) } : {}
    };
  });
  for (const bundle of bundles.assignments) for (const { report, provisionalDetourMinutes } of bundle.satellites) {
    const taskId = `satellite:${report.id}`;
    const allocation = assigned.get(taskId);
    const isSelected = Boolean(allocation) && !unusableGroups.has(bundle.group_key);
    items.push({ item_type: 'bundled_report', cluster_id: null, cluster_ids: [],
      anchor_cluster_id: anchorByKey.get(bundle.group_key).cluster_id,
      report_id: report.id, report_ids: [report.id], group_key: bundle.group_key,
      is_selected: isSelected,
      status: isSelected ? 'scheduled' : 'backlog',
      operational_label: isSelected ? 'Scheduled for dispatch' : 'Queued in backlog for next shift',
      planned_crew_id: allocation?.crewId ?? null, reason: unassigned.get(taskId) ??
        (unusableGroups.has(bundle.group_key) ? 'detour_cap_unenforceable' : 'selected'),
      estimated_duration_minutes: Math.ceil(report.workMinutes + provisionalDetourMinutes),
      estimated_work_minutes: Math.ceil(report.workMinutes), priority_score: report.base_priority_score,
      bundle_order: allocation?.order ?? null, detour_minutes: provisionalDetourMinutes,
      estimated_volume_m3: report.estimated_volume_m3, estimated_weight_kg: report.estimated_weight_kg,
      load_snapshot: allocation?.load ?? null,
      crew_snapshot: allocation ? { speed_factor: Number(crewById.get(allocation.crewId).speed_factor),
        service_time_factor: Number(crewById.get(allocation.crewId).service_time_factor) } : {} });
  }
  for (const task of tasks.filter(task => task.task_type === 'Sweeper')) {
    const report = reportById.get(task.id.slice('sweeper:'.length));
    const allocation = assigned.get(task.id);
    const isSelected = Boolean(allocation);
    items.push({ item_type: 'report', cluster_id: null, cluster_ids: [], report_id: report.id,
      report_ids: [report.id], group_key: task.group_key,
      is_selected: isSelected,
      status: isSelected ? 'scheduled' : 'backlog',
      operational_label: isSelected ? 'Scheduled for dispatch' : 'Queued in backlog for next shift',
      planned_crew_id: allocation?.crewId ?? null,
      reason: unassigned.get(task.id) ?? 'selected', estimated_duration_minutes: Math.ceil(report.workMinutes),
      estimated_work_minutes: Math.ceil(report.workMinutes), priority_score: report.base_priority_score,
      estimated_volume_m3: report.estimated_volume_m3, estimated_weight_kg: report.estimated_weight_kg,
      load_snapshot: allocation?.load ?? null,
      crew_snapshot: allocation ? { speed_factor: Number(crewById.get(allocation.crewId).speed_factor),
        service_time_factor: Number(crewById.get(allocation.crewId).service_time_factor) } : {} });
  }
  const generalistMinutes = generalists.reduce((sum, crew) => sum + crewCapacity(crew, settings), 0);
  const specialistMinutes = crews.filter(crew => crew.supports_sweeper && !crew.supports_standard)
    .reduce((sum, crew) => sum + crewCapacity(crew, settings), 0);
  // Provisional anchor reservations can be rejected by the solver. Report only
  // work that survived the final route validation.
  const assignedMinutes = items.filter(item => item.is_selected).reduce((sum, item) =>
    sum + Number(item.estimated_duration_minutes || 0), 0);
  const generalistUsed = items.filter(item => item.is_selected &&
    crewById.get(item.planned_crew_id)?.supports_standard).reduce((sum, item) =>
    sum + Number(item.estimated_duration_minutes || 0), 0);
  const specialistUsed = assignedMinutes - generalistUsed;
  const capacity = { availableCrews: vehicles.length, totalMinutes: Math.floor(generalistMinutes + specialistMinutes),
    generalist: { minutes: Math.floor(generalistMinutes), crews: generalists.length,
      maxTasks: generalists.reduce((sum, crew) => sum + (crew.max_tasks_per_shift ?? 10), 0),
      used: Math.ceil(generalistUsed), reserved: reserve },
    specialist: { minutes: Math.floor(specialistMinutes),
      crews: crews.filter(crew => crew.supports_sweeper && !crew.supports_standard).length,
      used: Math.ceil(specialistUsed) },
    used: Math.ceil(assignedMinutes) };
  const routeProposal = { ...proposal, travel_time_matrix_min: travel,
    node_ids: [...vehicles.map(vehicle => vehicle.id), ...tasks.map(task => task.id)],
    task_locations: Object.fromEntries(tasks.map(task => [task.id, task.location])),
    rejected_group_keys: [...unusableGroups] };
  const diagnostics = {
    ...(proposal.solver_diagnostics ?? {}),
    weather_adjustment: { condition: weatherCondition, multiplier: weatherMultiplier },
    matrix_fallback_used: matrixFallbackUsed,
    scheduled_count: items.filter(i => i.is_selected).length,
    backlog_count: items.filter(i => !i.is_selected).length
  };
  const { data: plan, error } = await db.rpc('save_mixed_dispatch_draft', {
    actor, job_id: jobId, worker_id: workerToken, settings, items, proposal: routeProposal,
    capacity, rejected, diagnostics });
  if (error) throw error;
  return { plan, diagnostics, rejectedBundles: rejected };
}
