import { fleetSettings } from '../services/fleetPolicy.js';
import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

import { prioritizeBacklog, getWorkQueue } from '../services/workQueue.service.js';
import { dispatchClusters } from '../services/dispatch.service.js';
import { commitAndRoutePlan } from '../services/dispatchCommit.service.js';
import { generateDispatchPlan } from '../services/dispatchPlanner.service.js';
import { enqueuePlan, readPlanJob, processNextPlanningJob } from '../services/planJobs.service.js';
import { processTaskFeedback } from '../services/taskFeedback.service.js';
import { metresBetween } from '../services/geoTime.js';
import { previewPlanDisassembly as svcPreviewDisassembly, disassemblePlan as svcDisassemblePlan } from '../services/planDisassembly.service.js';

// Phase 2: Work Queue Endpoints
export const prioritizeQueue = async (req, res, next) => {
  try {
    const updated = await prioritizeBacklog(req.body.weather_condition);
    res.status(200).json({ message: `Prioritized ${updated.length} clusters`, clusters: updated });
  } catch (error) { next(error); }
};

export const fetchWorkQueue = async (req, res, next) => {
  try {
    await prioritizeBacklog();
    
    // Parse the query parameter (it comes in as a string 'true' or 'false')
    const targetOutliersOnly = req.query.target_outliers_only === 'true'; 
    
    // Pass both parameters
    const queue = await getWorkQueue(parseInt(req.query.limit) || 100, targetOutliersOnly);
    res.status(200).json(queue);
  } catch (error) { next(error); }
};

export const explicitDispatch = async (req, res, next) => {
  try {
    const { cluster_ids } = req.body;
    if (!cluster_ids || !Array.isArray(cluster_ids)) {
      return res.status(400).json({ message: 'cluster_ids array is required' });
    }
    const result = await dispatchClusters(cluster_ids, req.user.id);
    res.status(result.routing_status === 'needs_replan' ? 202 : 201).json(result);
  } catch (error) { next(error); }
};

// Phase 3: Capacity-Aware Planning Endpoints
export const generatePlan = async (req, res, next) => {
  try {
    const { settings = {} } = req.body;
    const job = await enqueuePlan(req.user.id, settings, req.get('Idempotency-Key'));
    void processNextPlanningJob().catch(err => console.error('Immediate job processing error:', err));
    res.status(202).json(job);
  } catch (error) { next(error); }
};

export const getPlanJob = async (req, res, next) => {
  try {
    const job = await readPlanJob(req.params.jobId, req.user.id);
    if (!job) return res.status(404).json({ message: 'Planning job not found' });
    res.json(job);
  } catch (error) { next(error); }
};

// ── Optimization Templates ─────────────────────────────────────────────

/**
 * GET /api/optimization/templates
 * Returns all system-level presets (created_by = null) plus the current officer's saved templates.
 */
export const getTemplates = async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('optimization_templates')
      .select('*')
      .or(`created_by.is.null,created_by.eq.${req.user.id}`)
      .order('is_default', { ascending: false })
      .order('created_at', { ascending: true });

    if (error) return res.status(400).json({ message: 'Failed to fetch templates', error: error.message });
    res.status(200).json(data);
  } catch (error) { next(error); }
};

/**
 * POST /api/optimization/templates
 * Saves the current officer's settings as a new named template.
 */
export const createTemplate = async (req, res, next) => {
  try {
    const { name, description, settings } = req.body;
    if (!name || typeof name !== 'string' || name.trim() === '') {
      return res.status(400).json({ message: 'Template name is required' });
    }
    if (!settings || typeof settings !== 'object') {
      return res.status(400).json({ message: 'Template settings payload is required' });
    }

    const { data, error } = await supabase
      .from('optimization_templates')
      .insert({
        name: name.trim(),
        description: description?.trim() || null,
        created_by: req.user.id,
        is_default: false,
        settings
      })
      .select()
      .single();

    if (error) return res.status(400).json({ message: 'Failed to save template', error: error.message });
    res.status(201).json({ message: 'Template saved successfully', template: data });
  } catch (error) { next(error); }
};

/**
 * DELETE /api/optimization/templates/:id
 * Deletes one of the officer's own custom templates. System presets (is_default) cannot be deleted.
 */
export const deleteTemplate = async (req, res, next) => {
  try {
    const { id } = req.params;

    // Verify ownership and that this is not a system preset
    const { data: existing, error: fetchError } = await supabase
      .from('optimization_templates')
      .select('id, created_by, is_default')
      .eq('id', id)
      .single();

    if (fetchError || !existing) return res.status(404).json({ message: 'Template not found' });
    if (existing.is_default) return res.status(403).json({ message: 'System preset templates cannot be deleted' });
    if (existing.created_by !== req.user.id) return res.status(403).json({ message: 'You can only delete your own templates' });

    const { error } = await supabase.from('optimization_templates').delete().eq('id', id);
    if (error) return res.status(400).json({ message: 'Failed to delete template', error: error.message });
    res.status(200).json({ message: 'Template deleted successfully' });
  } catch (error) { next(error); }
};

export const getPlanItems = async (req, res, next) => {
  try {
    const { id } = req.params;
    const planQuery = supabase.from?.('dispatch_plans');
    if (planQuery?.select) {
      const { data: plan, error: planError } = await planQuery
        .select('id, created_by')
        .eq('id', id)
        .maybeSingle();
      if (planError) throw planError;
      if (!plan) return res.status(404).json({ message: 'Plan not found' });
      if (req.user.role !== 'admin' && plan.created_by && plan.created_by !== req.user.id) {
        return res.status(403).json({ message: 'Access denied: plan belongs to another officer or tenant' });
      }
    }
    const { data, error } = await supabase
      .from('dispatch_plan_items')
      .select('*, clusters(issue_type, priority_score, recommended_task_type), reports!dispatch_plan_items_report_id_fkey(issue_type, severity_score)')
      .eq('dispatch_plan_id', id)
      .order('is_selected', { ascending: false });

    if (error) return res.status(400).json({ message: 'Failed to fetch plan items', error: error.message });
    res.status(200).json(data);
  } catch (error) { next(error); }
};

export const getPlan = async (req, res, next) => {
  try {
    const planQuery = supabase.from?.('dispatch_plans');
    let plan = null;
    if (planQuery?.select) {
      const { data: fetchedPlan, error } = await planQuery
        .select('id,mode,status,planned_date,created_at,settings_snapshot,capacity_breakdown,rejected_bundles,solver_diagnostics,planning_as_of,total_capacity_minutes,total_crews_available,route_proposal,created_by')
        .eq('id', req.params.id).maybeSingle();
      if (error) throw error;
      if (!fetchedPlan) return res.status(404).json({ message: 'Plan not found' });
      if (req.user.role !== 'admin' && fetchedPlan.created_by && fetchedPlan.created_by !== req.user.id) {
        return res.status(403).json({ message: 'Access denied: plan belongs to another officer or tenant' });
      }
      plan = fetchedPlan;
    }
    if (!plan) return res.status(404).json({ message: 'Plan not found' });
    const { data: items, error: itemError } = await supabase.from('dispatch_plan_items')
      .select('*').eq('dispatch_plan_id', plan.id).order('group_key').order('bundle_order');
    if (itemError) throw itemError;
    const groups = [];
    const byKey = new Map();
    for (const item of items ?? []) {
      if (item.item_type === 'bundled_report') continue;
      const group = { group_key: item.group_key, anchor: item, satellites: [] };
      byKey.set(item.group_key, group);
      groups.push(group);
    }
    for (const item of items ?? []) if (item.item_type === 'bundled_report')
      byKey.get(item.group_key)?.satellites.push(item);
    const selected = (items ?? []).filter(item => item.is_selected);
    const selectedMinutes = selected.reduce((sum, item) => sum + Number(item.estimated_duration_minutes || 0), 0);
    const plannedCrews = new Set(selected.map(item => item.planned_crew_id).filter(Boolean));
    const capacity = plan.mode === 'mixed' ? plan.capacity_breakdown ?? {} : {
      availableCrews: plan.total_crews_available ?? 0,
      totalMinutes: plan.total_capacity_minutes ?? 0,
      generalist: { used: plan.mode === 'standard' ? selectedMinutes : 0,
        minutes: plan.mode === 'standard' ? plan.total_capacity_minutes ?? 0 : 0,
        reserved: 0 },
      specialist: { used: plan.mode === 'sweeper' ? selectedMinutes : 0,
        minutes: plan.mode === 'sweeper' ? plan.total_capacity_minutes ?? 0 : 0 },
      used: selectedMinutes
    };
    const depotSetting = plan.settings_snapshot?.depot;
    const depotLat = Number(depotSetting?.lat ?? depotSetting?.latitude ?? 14.561433);
    const depotLng = Number(depotSetting?.lng ?? depotSetting?.longitude ?? 121.075636);

    const { data: dbCrews } = await supabase.from('field_crews').select('id, name');
    const crewNameMap = new Map((dbCrews ?? []).map(c => [c.id, c.name]));

    const taskLocations = plan.route_proposal?.task_locations ?? {};
    const travelMatrix = plan.route_proposal?.travel_time_matrix_min;
    const nodeIds = plan.route_proposal?.node_ids ?? [];
    const nodeIndexMap = new Map(nodeIds.map((id, index) => [id, index]));

    const proposedRoutes = (plan.route_proposal?.routes ?? []).filter(route => route.stops?.length).map((route, routeIdx) => {
      const waypoints = [];
      waypoints.push({
        id: `depot-start-${route.vehicle_id}`,
        sequence_order: 0,
        latitude: depotLat,
        longitude: depotLng,
        waypoint_type: 'depot_start',
        distance_from_previous_meters: 0,
        estimated_time_from_previous_min: 0,
      });

      let prevLoc = { lat: depotLat, lng: depotLng };
      let prevNodeId = route.vehicle_id;

      (route.stops ?? []).forEach((stop, stopIdx) => {
        const loc = taskLocations[stop.task_id];
        const lat = Number(loc?.lat);
        const lng = Number(loc?.lng);
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) return;

        let distMeters = 0;
        try {
          distMeters = Math.ceil(metresBetween(prevLoc, { lat, lng }));
        } catch (_) {}

        const fromIdx = nodeIndexMap.get(prevNodeId);
        const toIdx = nodeIndexMap.get(stop.task_id);
        const durMin = (fromIdx != null && toIdx != null && travelMatrix?.[fromIdx]?.[toIdx] != null)
          ? Math.ceil(travelMatrix[fromIdx][toIdx])
          : Math.ceil(distMeters / 500);

        const matchedItem = (items ?? []).find(it => it.group_key === stop.task_id || it.report_id === stop.task_id.replace(/^(satellite|sweeper):/, ''));

        waypoints.push({
          id: `stop-${route.vehicle_id}-${stopIdx + 1}`,
          sequence_order: stopIdx + 1,
          latitude: lat,
          longitude: lng,
          cleanup_task_id: stop.task_id,
          waypoint_type: 'task',
          cleanup_tasks: {
            id: stop.task_id,
            task_type: stop.task_id.startsWith('satellite:') || stop.task_id.startsWith('sweeper:') ? 'Scouting' : 'Cleanup',
            report_ids: matchedItem?.report_ids ?? []
          },
          distance_from_previous_meters: distMeters,
          estimated_time_from_previous_min: durMin
        });

        prevLoc = { lat, lng };
        prevNodeId = stop.task_id;
      });

      let returnDistMeters = 0;
      try {
        returnDistMeters = Math.ceil(metresBetween(prevLoc, { lat: depotLat, lng: depotLng }));
      } catch (_) {}

      const lastFromIdx = nodeIndexMap.get(prevNodeId);
      const depotIdx = nodeIndexMap.get(route.vehicle_id);
      const returnDurMin = (lastFromIdx != null && depotIdx != null && travelMatrix?.[lastFromIdx]?.[depotIdx] != null)
        ? Math.ceil(travelMatrix[lastFromIdx][depotIdx])
        : Math.ceil(returnDistMeters / 500);

      waypoints.push({
        id: `depot-end-${route.vehicle_id}`,
        sequence_order: waypoints.length,
        latitude: depotLat,
        longitude: depotLng,
        waypoint_type: 'depot_end',
        distance_from_previous_meters: returnDistMeters,
        estimated_time_from_previous_min: returnDurMin
      });

      const totalDist = Number(route.total_distance_m) || waypoints.reduce((sum, w) => sum + (w.distance_from_previous_meters || 0), 0);
      const totalDur = Number(route.total_duration_min) || waypoints.reduce((sum, w) => sum + (w.estimated_time_from_previous_min || 0), 0);
      const crewName = crewNameMap.get(route.vehicle_id) || `Crew ${routeIdx + 1}`;

      return {
        id: route.vehicle_id,
        crewId: route.vehicle_id,
        vehicle_id: route.vehicle_id,
        field_crews: { id: route.vehicle_id, name: crewName },
        task_count: (route.stops ?? []).length,
        distanceMeters: totalDist,
        total_distance_meters: totalDist,
        durationMinutes: totalDur,
        total_duration_min: totalDur,
        waypoints,
        isDraft: true
      };
    });
    const { route_proposal: _routeProposal, ...publicPlan } = plan;
    res.json({ plan: publicPlan, items, groups, capacity, plannedCrewCount: plannedCrews.size,
      proposedRoutes,
      rejectedBundles: plan.rejected_bundles ?? [], settings: plan.settings_snapshot });
  } catch (error) { next(error); }
};

export const commitPlan = async (req, res, next) => {
  try {
    const planQuery = supabase.from?.('dispatch_plans');
    if (planQuery?.select) {
      const { data: plan, error: planError } = await planQuery
        .select('id, created_by')
        .eq('id', req.params.id)
        .maybeSingle();
      if (planError) throw planError;
      if (!plan) return res.status(404).json({ message: 'Plan not found' });
      if (req.user.role !== 'admin' && plan.created_by && plan.created_by !== req.user.id) {
        return res.status(403).json({ message: 'Access denied: cannot commit a plan created by another officer or tenant' });
      }
    }
    const result = await commitAndRoutePlan(req.params.id, req.user.id);
    res.status(result.routing_status === 'needs_replan' || result.routing_status === 'routing' ? 202 : 200).json(result);
  } catch (error) { next(error); }
};

export const runOptimization = async (req, res, next) => {
  try {
    const generated = await generateDispatchPlan(req.user.id, req.body.settings ?? {});
    const result = await commitAndRoutePlan(generated.plan.id, req.user.id);
    res.status(result.routing_status === 'needs_replan' ? 202 : 200).json({ ...generated, ...result });
  } catch (error) { next(error); }
};

export const approveOptimization = async (req, res, next) => {
  try {
    const planQuery = supabase.from?.('dispatch_plans');
    if (planQuery?.select) {
      const { data, error } = await planQuery.select('id, created_by').eq('optimization_run_id',req.params.id).maybeSingle();
      if (error) throw error;
      if (!data) return res.status(409).json({ message: 'Legacy runs cannot claim reports. Generate a new dispatch plan.' });
      if (req.user.role !== 'admin' && data.created_by && data.created_by !== req.user.id) {
        return res.status(403).json({ message: 'Access denied: cannot approve run created by another officer or tenant' });
      }
      return res.json(await commitAndRoutePlan(data.id, req.user.id));
    }
    res.json(await commitAndRoutePlan(req.params.id, req.user.id));
  } catch (error) { next(error); }
};

export const discardOptimization = async (req, res, next) => {
  const { id } = req.params;
  
  try {
    const { data: run, error: runError } = await supabase
      .from('optimization_runs')
      .select('status')
      .eq('id', id)
      .single();
      
    if (runError) throw runError;
    if (run.status !== 'proposed') {
      return res.status(400).json({ message: 'Can only discard proposed optimization runs' });
    }
    
    // 1. Discard run
    const { data: discardedRun, error: updateError } = await supabase
      .from('optimization_runs')
      .update({
        status: 'discarded'
      })
      .eq('id', id)
      .select()
      .single();
      
    if (updateError) throw updateError;
    
    res.status(200).json({ message: 'Optimization discarded', run: discardedRun });
  } catch (error) { next(error); }
};

export const previewPlanDisassembly = async (req, res, next) => {
  try {
    const planQuery = supabase.from?.('dispatch_plans');
    if (planQuery?.select) {
      const { data: plan, error: planError } = await planQuery
        .select('id, created_by')
        .or(`id.eq.${req.params.id},optimization_run_id.eq.${req.params.id}`)
        .maybeSingle();
      if (planError) throw planError;
      if (plan && req.user.role !== 'admin' && plan.created_by && plan.created_by !== req.user.id) {
        return res.status(403).json({ message: 'Access denied: cannot preview disassembly for another officer or tenant' });
      }
    }
    const preview = await svcPreviewDisassembly(req.params.id);
    res.status(200).json(preview);
  } catch (error) { next(error); }
};

export const disassemblePlan = async (req, res, next) => {
  try {
    const planQuery = supabase.from?.('dispatch_plans');
    if (planQuery?.select) {
      const { data: plan, error: planError } = await planQuery
        .select('id, created_by')
        .or(`id.eq.${req.params.id},optimization_run_id.eq.${req.params.id}`)
        .maybeSingle();
      if (planError) throw planError;
      if (plan && req.user.role !== 'admin' && plan.created_by && plan.created_by !== req.user.id) {
        return res.status(403).json({ message: 'Access denied: cannot disassemble a plan created by another officer or tenant' });
      }
    }
    const result = await svcDisassemblePlan(req.params.id, req.user.id);
    res.status(200).json(result);
  } catch (error) { next(error); }
};

// List all optimization runs
export const getOptimizationRuns = async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('optimization_runs')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) return res.status(400).json({ message: 'Failed to fetch runs', error: error.message });
    res.json(data);
  } catch (error) { next(error); }
};

// Get single optimization run with routes
export const getOptimizationRunById = async (req, res, next) => {
  try {
    const { id } = req.params;
    const { data: run, error } = await supabase
      .from('optimization_runs')
      .select('*')
      .eq('id', id)
      .single();

    if (error) return res.status(404).json({ message: 'Run not found', error: error.message });

    const { data: routes } = await supabase
      .from('crew_routes')
      .select('*, field_crews(name)')
      .eq('optimization_run_id', id);

      if (routes && routes.length > 0) {
        const routeIds = routes.map(r => r.id);
        const { data: waypoints } = await supabase
          .from('route_waypoints')
          .select('*, cleanup_tasks(id, task_type, report_ids)')
          .in('crew_route_id', routeIds)
          .order('sequence_order', { ascending: true });
        
      for (const route of routes) {
        route.waypoints = (waypoints || []).filter(w => w.crew_route_id === route.id);
      }
    }

    res.json({ ...run, routes: routes || [] });
  } catch (error) { next(error); }
};

async function visibleCrewIds(req) {
  if (req.user.role !== 'field_crew') return null;
  const { data, error } = await supabase.from('field_crews').select('id, member_profile_ids, team_lead_profile_id');
  if (error) throw error;
  return (data ?? []).filter(crew => crew.team_lead_profile_id === req.user.id || crew.member_profile_ids?.includes(req.user.id)).map(crew => crew.id);
}

async function canReadCrewRoute(req, routeId) {
  const ids = await visibleCrewIds(req);
  if (ids === null) return true;
  const { data, error } = await supabase.from('crew_routes').select('crew_id').eq('id', routeId).maybeSingle();
  if (error) throw error;
  return Boolean(data && ids.includes(data.crew_id));
}

// Get active (approved) routes
export const getActiveRoutes = async (req, res, next) => {
  try {
    // Find the most recent approved run
    const { data: run } = await supabase
      .from('optimization_runs')
      .select('id')
      .eq('status', 'approved')
      .not('approved_at', 'is', null)
      .order('approved_at', { ascending: false })
      .limit(1)
      .single();

    if (!run) return res.json({ routes: [] });

    const ids = await visibleCrewIds(req);
    if (ids && !ids.length) return res.json({ optimization_run_id: run.id, routes: [] });
    let query = supabase.from('crew_routes').select('*, field_crews(name)').eq('optimization_run_id', run.id);
    if (ids) query = query.in('crew_id', ids);
    const { data: routes, error } = await query;
    if (error) throw error;

    for (const route of (routes || [])) {
      const { data: waypoints } = await supabase
        .from('route_waypoints')
        .select('*, cleanup_tasks(id, task_type)')
        .eq('crew_route_id', route.id)
        .order('sequence_order');
      route.waypoints = waypoints || [];
    }

    res.json({ optimization_run_id: run.id, routes });
  } catch (error) { next(error); }
};

export const getRouteById = async (req, res, next) => {
  try {
    const { routeId } = req.params;
    if (!await canReadCrewRoute(req, routeId)) return res.status(403).json({ message: 'Route is not assigned to your crew' });
    const { data, error } = await supabase
      .from('crew_routes')
      .select('*, field_crews(name)')
      .eq('id', routeId)
      .single();

    if (error) return res.status(404).json({ message: 'Route not found' });

    const { data: waypoints } = await supabase
      .from('route_waypoints')
      .select('*')
      .eq('crew_route_id', routeId)
      .order('sequence_order');

    res.json({ ...data, waypoints: waypoints || [] });
  } catch (error) { next(error); }
};

export const getRouteWaypoints = async (req, res, next) => {
  try {
    const { routeId } = req.params;
    if (!await canReadCrewRoute(req, routeId)) return res.status(403).json({ message: 'Route is not assigned to your crew' });
    const { data, error } = await supabase
      .from('route_waypoints')
      .select('*')
      .eq('crew_route_id', routeId)
      .order('sequence_order');

    if (error) return res.status(400).json({ message: 'Failed to fetch waypoints' });
    res.json(data || []);
  } catch (error) { next(error); }
};

export const getFieldCrews = async (req, res, next) => {
  try {
    const { data: crews, error } = await supabase
      .from('field_crews')
      .select('*')
      .order('name');

    if (error) return res.status(400).json({ message: 'Failed to fetch crews' });

    // Fetch active cleanup tasks (not completed and not cancelled)
    const { data: activeTasks, error: tasksError } = await supabase
      .from('cleanup_tasks')
      .select('id, title, status, priority_score, scheduled_date, assigned_field_crew_id, assigned_crew_ids')
      .in('status', ['created', 'pending', 'in_progress', 'partially_completed']);

    if (tasksError) {
      console.warn('Failed to fetch active tasks for crews:', tasksError.message);
    }

    const tasksList = activeTasks || [];

    // Enrich each crew with member profile data and active task count/list
    const enriched = await Promise.all(
      crews.map(async (crew) => {
        const memberIds = crew.member_profile_ids || [];
        let members = [];
        if (memberIds.length > 0) {
          const { data: profiles } = await supabase
            .from('profiles')
            .select('id, full_name, avatar_url')
            .in('id', memberIds);
          members = profiles || [];
        }

        const crewTasks = tasksList.filter((t) =>
          t.assigned_field_crew_id === crew.id ||
          (Array.isArray(t.assigned_crew_ids) && memberIds.some((mId) => t.assigned_crew_ids.includes(mId)))
        );

        const maxTasks = Number(crew.max_tasks_per_shift) || 10;
        const activeTaskCount = crewTasks.length;

        return {
          ...crew,
          members,
          active_task_count: activeTaskCount,
          assigned_tasks_count: activeTaskCount,
          active_tasks: crewTasks.map((t) => ({
            id: t.id,
            title: t.title || 'Cleanup Task',
            status: t.status,
            priority_score: t.priority_score,
            scheduled_date: t.scheduled_date
          })),
          max_tasks_per_shift: maxTasks,
          is_at_capacity: activeTaskCount >= maxTasks
        };
      })
    );

    res.json(enriched);
  } catch (error) { next(error); }
};

export const updateCrewMembers = async (req, res, next) => {
  try {
    const { user_id, action } = req.body;
    const crew_id = req.params.id;

    if (!crew_id) {
      return res.status(400).json({ message: 'Crew ID is required in URL path' });
    }
    if (!user_id) {
      return res.status(400).json({ message: 'user_id is required in request body' });
    }
    if (!action || !['add', 'remove'].includes(action)) {
      return res.status(400).json({ message: 'action must be either "add" or "remove"' });
    }

    const { data, error } = await supabase.rpc('change_field_crew_member', {
      crew_id,
      actor: req.user.id,
      member_id: user_id,
      action
    });

    if (error) {
      return res.status(400).json({
        message: error.message || error.details || 'Failed to update crew member',
        error: error.message
      });
    }

    return res.status(200).json(data);
  } catch (error) {
    return res.status(error.statusCode || 400).json({
      message: error.message || 'Failed to update crew member',
      error: error.message
    });
  }
};

export const getUnassignedMembers = async (req, res, next) => {
  try {
    // Get all field_crew role users
    const { data: fcUsers, error: profilesError } = await supabase
      .from('profiles')
      .select('id, full_name, avatar_url, role')
      .eq('role', 'field_crew')
      .order('full_name');

    if (profilesError) return res.status(400).json({ message: 'Failed to fetch field crew users' });

    // Get all assigned member IDs across all crews (including team leads)
    const { data: crews } = await supabase
      .from('field_crews')
      .select('member_profile_ids, team_lead_profile_id');

    const assignedIds = new Set(
      (crews || []).flatMap(c => [
        ...(c.member_profile_ids || []),
        c.team_lead_profile_id
      ]).filter(Boolean)
    );

    const unassigned = (fcUsers || []).filter(u => !assignedIds.has(u.id));
    res.json(unassigned);
  } catch (error) { next(error); }
};

export const getOptimizationSettings = async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('optimization_settings')
      .select('*')
      .order('key');

    if (error) return res.status(400).json({ message: 'Failed to fetch settings' });
    res.json(data);
  } catch (error) { next(error); }
};

export const updateOptimizationSettings = async (req, res, next) => {
  try {
    const { key, value } = req.body;
    const { data, error } = await supabase
      .from('optimization_settings')
      .update({ value, updated_by: req.user.id, updated_at: new Date().toISOString() })
      .eq('key', key)
      .select()
      .single();

    if (error) return res.status(400).json({ message: 'Failed to update setting', error: error.message });
    res.json(data);
  } catch (error) { next(error); }
};

// Phase 15: Admin crew management
export const createFieldCrew = async (req,res,next) => {
  try {
    const fleet = fleetSettings(req.body,true);
    if (fleet.hazmat_certified) fleet.certification_reviewed_by = req.user.id;
    const {data,error}=await supabase.from('field_crews').insert(fleet).select().single();
    if(error) throw error;res.status(201).json(data);
  } catch(error){next(error);}
};
export const updateFieldCrew = async (req,res,next) => {
  try {
    const fleet = fleetSettings(req.body);
    if (fleet.hazmat_certified !== undefined) fleet.certification_reviewed_by = req.user.id;
    const {data,error}=await supabase.from('field_crews').update({...fleet,updated_at:new Date().toISOString()}).eq('id',req.params.id).select().single();
    if(error) throw error;res.json(data);
  } catch(error){next(error);}
};

// Phase 6: Field Feedback Loop
export const completeTask = async (req, res, next) => {
  const { id } = req.params;
  const { outcome, notes } = req.body;
  
  if (!outcome) {
    return res.status(400).json({ message: 'Outcome is required' });
  }

  try {
    const updatedTask = await processTaskFeedback(id, outcome, notes, req.user.id, req.body);
    res.status(200).json({ 
      message: 'Task completed and clusters updated successfully', 
      task: updatedTask 
    });
  } catch (error) { next(error); }
};

export const generateSweeperRoutes = async (req, res, next) => {
  try {
    if (req.body.clusterIds?.length || req.body.crewId) return res.status(400).json({ message: 'Sweeper dispatch uses eligible report IDs and fleet capabilities. Use settings.report_ids.' });
    const generated = await generateDispatchPlan(req.user.id, { ...req.body.settings, mode: 'sweeper' });
    const result = await commitAndRoutePlan(generated.plan.id, req.user.id);
    res.status(result.routing_status === 'needs_replan' ? 202 : 200).json({ ...generated, ...result });
  } catch (error) { next(error); }
};

export const getDispatchBlocks = async (req,res,next) => {
  try {
    const {data,error}=await supabase.from('dispatch_access_blocks').select('*').is('cleared_at',null).order('blocked_at').limit(200);
    if(error) throw error;res.json(data);
  } catch(error){next(error);}
};
export const clearDispatchBlock = async (req,res,next) => {
  try {
    const {data,error}=await supabase.rpc('clear_dispatch_block',{block_id:req.params.id,actor:req.user.id,notes:req.body.notes});
    if(error) throw error;res.json(data);
  } catch(error){next(error);}
};

export const getOptimizationOptions = async (req, res, next) => {
  try {
    const { data: settingsRows, error: settingsError } = await supabase
      .from('optimization_settings')
      .select('key, value');
    if (settingsError) throw settingsError;

    const settingsMap = Object.fromEntries(
      (settingsRows || []).map(r => [r.key, r.value])
    );

    const { data: crewVehicles } = await supabase
      .from('field_crews')
      .select('vehicle_type')
      .not('vehicle_type', 'is', null);

    const activeVehicleTypes = Array.from(
      new Set((crewVehicles || []).map(c => c.vehicle_type).filter(Boolean))
    );

    const options = {
      travel_modes: [
        { value: 'WALKING', label: 'Walking' },
        { value: 'BICYCLE', label: 'Bicycle' },
        { value: 'MOTORCYCLE', label: 'Motorcycle' },
        { value: 'DRIVING', label: 'Vehicle' }
      ],
      task_types: [
        'Cleanup',
        'Investigation',
        'Verification',
        'Emergency Response',
        'Reinspection',
        'Monitoring',
        'Escalation',
        'Deferred'
      ],
      overtime_options: [
        { label: '+0 min', value: 0 },
        { label: '+15 min', value: 15 },
        { label: '+30 min', value: 30 },
        { label: '+60 min', value: 60 }
      ],
      break_durations: [0, 15, 30, 60, 90],
      workflow_targets: [
        { value: 'standard', label: 'Clusters' },
        { value: 'sweeper', label: 'Sweepers' },
        { value: 'mixed', label: 'Mixed' }
      ],
      vehicle_types: activeVehicleTypes.length ? activeVehicleTypes : ['compactor', 'pickup', 'tricycle', 'motorcycle', 'walking'],
      depot: settingsMap.swmo_depot || {
        name: 'SWMO Depot (PLP Center)',
        latitude: 14.561616769364207,
        longitude: 121.07466280460359
      },
      defaults: {
        travel_mode: 'DRIVING',
        break_duration_min: 60,
        overtime_tolerance_min: 15,
        max_tasks_per_shift: 15,
        capacity_utilization: 1.0
      }
    };

    res.status(200).json(options);
  } catch (error) { next(error); }
};
