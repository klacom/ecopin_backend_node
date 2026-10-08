const DEFAULT_WEIGHTS = { severity: 0.4, urgency: 0.25, report_count: 0.15, waiting_time: 0.15, weather: 0.05 };
function badInput(message) { const error = new Error(message); error.statusCode = 400; return error; }

export function resolvePlanSettings(input = {}) {
  if (!input || Array.isArray(input) || typeof input !== 'object') throw badInput('settings must be an object');
  const settings = { mode: 'standard', travel_mode: 'DRIVING', break_duration_min: 60, overtime_tolerance_min: 15, max_tasks_per_shift: 15, capacity_utilization: 1, ...input };
  if (!['standard', 'sweeper'].includes(settings.mode)) throw badInput('Slice A supports standard or sweeper mode');
  for (const [key, min, max] of [['break_duration_min', 0, 240], ['overtime_tolerance_min', 0, 120], ['max_tasks_per_shift', 1, 100], ['capacity_utilization', 0.1, 1]]) {
    if (typeof settings[key] !== 'number' || !Number.isFinite(settings[key]) || settings[key] < min || settings[key] > max) throw badInput(`Invalid ${key}`);
  }
  if (!Number.isInteger(settings.max_tasks_per_shift)) throw badInput('max_tasks_per_shift must be an integer');
  if (!['DRIVING', 'BICYCLE', 'WALKING'].includes(settings.travel_mode)) throw badInput('Invalid travel_mode');
  if (settings.zone_ids?.length) throw badInput('Zone filtering requires a configured spatial zone model');
  for (const key of ['cluster_ids','report_ids']) {
    if (settings[key] !== undefined && (!Array.isArray(settings[key]) || settings[key].length>200 || !settings[key].every(id => typeof id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)))) throw badInput(`Invalid ${key}`);
  }
  return settings;
}

export function normalizeWeights(weights = DEFAULT_WEIGHTS) {
  const values = Object.fromEntries(Object.keys(DEFAULT_WEIGHTS).map(key => [key, weights[key] ?? 0]));
  if (Object.values(values).some(value => typeof value !== 'number' || !Number.isFinite(value) || value < 0)) throw badInput('Invalid MCDA weights');
  const total = Object.values(values).reduce((sum, value) => sum + value, 0);
  if (total <= 0) throw badInput('MCDA weights must include a positive value');
  return Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value / total]));
}

export function reportPriority(report, weights, now = Date.now()) {
  const normalized = normalizeWeights(weights);
  const age = Math.max(0, (now - Date.parse(report.sla_started_at ?? report.created_at)) / 3600000) || 0;
  const terms = { severity: Math.max(0, Math.min(100, report.severity_score ?? 0)), urgency: Math.max(0, Math.min(100, ((report.urgency_score ?? 1) - 1) * 50)), report_count: 10, waiting_time: Math.min(100, age / 168 * 100), weather: 0 };
  return Math.round(Object.entries(normalized).reduce((sum, [key, weight]) => sum + weight * terms[key], 0) * 10) / 10;
}

function shiftMinutes(crew) {
  const parse = value => { const [h, m] = value.split(':').map(Number); return h * 60 + m; };
  let minutes = parse(crew.shift_end) - parse(crew.shift_start);
  if (minutes < 0) minutes += 1440;
  return minutes;
}

export function selectPlanItems(candidates, crews, activeTasks, settings) {
  const travel = { DRIVING: 25, BICYCLE: 15, WALKING: 10 }[settings.travel_mode];
  const capable = crews.filter(crew => crew.availability_status === 'available' && crew.shift_start && crew.shift_end && (settings.mode === 'sweeper' ? crew.supports_sweeper : crew.supports_standard) && ((crew.member_profile_ids?.length ?? 0) > 0 || crew.team_lead_profile_id));
  const budgets = capable.map(crew => {
    const members = [...(crew.member_profile_ids ?? []), crew.team_lead_profile_id].filter(Boolean);
    const busy = activeTasks.filter(task => !['completed', 'cancelled'].includes(task.status) && (task.assigned_field_crew_id === crew.id || task.assigned_crew_ids?.some(id => members.includes(id))));
    const total = Math.max(0, (shiftMinutes(crew) - settings.break_duration_min + settings.overtime_tolerance_min) * settings.capacity_utilization);
    return { crew, total, remaining: Math.max(0, total - busy.reduce((sum, task) => sum + (task.estimated_duration_min ?? 60), 0)), count: busy.length, cap: Math.min(crew.max_tasks_per_shift ?? 10, settings.max_tasks_per_shift) };
  });
  const items = [...candidates].sort((a, b) => Number(b.lifecycle_state === 'sla_breached') - Number(a.lifecycle_state === 'sla_breached') || b.priority_score - a.priority_score || a.group_key.localeCompare(b.group_key)).map(candidate => {
    const eligible = budgets.map(budget => ({ budget, minutes: Math.ceil(candidate.service_minutes * Number(budget.crew.service_time_factor) + travel / Number(budget.crew.speed_factor)) }))
      .filter(({ budget, minutes }) => budget.remaining >= minutes && budget.count < budget.cap)
      .sort((a, b) => b.budget.remaining - a.budget.remaining || a.budget.crew.id.localeCompare(b.budget.crew.id));
    const chosen = eligible[0];
    if (chosen) { chosen.budget.remaining -= chosen.minutes; chosen.budget.count++; }
    return { ...candidate, crew_snapshot: chosen ? { speed_factor: Number(chosen.budget.crew.speed_factor), service_time_factor: Number(chosen.budget.crew.service_time_factor) } : {}, is_selected: Boolean(chosen), planned_crew_id: chosen?.budget.crew.id ?? null, estimated_work_minutes: Math.ceil(candidate.service_minutes * Number(chosen?.budget.crew.service_time_factor ?? 1)), estimated_duration_minutes: chosen?.minutes ?? Math.ceil(candidate.service_minutes + travel), reason: chosen ? 'selected' : capable.length ? 'insufficient_capacity' : 'no_capable_crew' };
  });
  return { items, totalCapacityMinutes: Math.floor(budgets.reduce((sum, budget) => sum + budget.total, 0)), capacityUtilized: budgets.reduce((sum, budget) => sum + budget.total - budget.remaining, 0) };
}
