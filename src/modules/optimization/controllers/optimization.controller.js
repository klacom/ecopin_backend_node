import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

import { calculateClusterPriorities } from '../services/mcdaPrioritizer.service.js';
import { mapClustersToTasks } from '../services/clusterTaskMapper.service.js';
import { assignTasksToCrews } from '../services/crewAssigner.service.js';
import { generateRouteForCrew } from '../services/routeGenerator.service.js';
import { applyWeatherSimulation } from '../services/weatherSimulator.service.js';
import { applyTrafficSimulation } from '../services/trafficSimulator.service.js';
import { prioritizeBacklog, getWorkQueue } from '../services/workQueue.service.js';
import { dispatchClusters } from '../services/dispatch.service.js';
import { generateDispatchPlan } from '../services/dispatchPlanner.service.js';
import { processTaskFeedback } from '../services/taskFeedback.service.js';

async function loadWeights() {
  const { data } = await supabase.from('optimization_settings').select('value').eq('key', 'mcda_weights').single();
  return data?.value || { severity: 0.40, urgency: 0.25, report_count: 0.15, waiting_time: 0.15, weather: 0.05 };
}

async function getDepot() {
  const { data } = await supabase.from('optimization_settings').select('value').eq('key', 'swmo_depot').single();
  return data?.value || { latitude: 14.561433, longitude: 121.075636 };
}

async function findEligibleClusters() {
  const { data } = await supabase.from('clusters').select('id').eq('status', 'unresolved');
  return data || [];
}

async function loadFieldCrews() {
  const { data } = await supabase.from('field_crews').select('*').eq('availability_status', 'available');
  return data || [];
}

// Phase 2: Work Queue Endpoints
export const prioritizeQueue = async (req, res, next) => {
  try {
    const updated = await prioritizeBacklog(req.body.weather_condition);
    res.status(200).json({ message: `Prioritized ${updated.length} clusters`, clusters: updated });
  } catch (error) { next(error); }
};

export const fetchWorkQueue = async (req, res, next) => {
  try {
    const queue = await getWorkQueue(parseInt(req.query.limit) || 100);
    res.status(200).json(queue);
  } catch (error) { next(error); }
};

export const explicitDispatch = async (req, res, next) => {
  try {
    const { cluster_ids } = req.body;
    if (!cluster_ids || !Array.isArray(cluster_ids)) {
      return res.status(400).json({ message: 'cluster_ids array is required' });
    }
    const tasks = await dispatchClusters(cluster_ids, req.user.id);
    res.status(201).json({ message: `Dispatched ${tasks.length} tasks from ${cluster_ids.length} clusters`, tasks });
  } catch (error) { next(error); }
};

// Phase 3: Capacity-Aware Planning Endpoints
export const generatePlan = async (req, res, next) => {
  try {
    const result = await generateDispatchPlan(req.user.id);
    res.status(201).json({ message: 'Dispatch plan generated successfully', ...result });
  } catch (error) { next(error); }
};

export const getPlanItems = async (req, res, next) => {
  try {
    const { id } = req.params;
    const { data, error } = await supabase
      .from('dispatch_plan_items')
      .select('*, clusters(issue_type, priority_score, recommended_task_type)')
      .eq('dispatch_plan_id', id)
      .order('is_selected', { ascending: false });

    if (error) return res.status(400).json({ message: 'Failed to fetch plan items', error: error.message });
    res.status(200).json(data);
  } catch (error) { next(error); }
};

export const commitPlan = async (req, res, next) => {
  try {
    const { id } = req.params;
    const { weather_condition = 'normal', traffic_condition = 'low' } = req.body;
    
    console.log(`[Optimization] Committing plan ${id}...`);
    // 1. Fetch the plan
    console.log(`[Optimization] Step 1: Fetching draft plan...`);
    const { data: plan, error: planError } = await supabase.from('dispatch_plans').select('status').eq('id', id).single();
    if (planError || !plan) return res.status(404).json({ message: 'Plan not found' });
    if (plan.status !== 'draft') return res.status(400).json({ message: 'Only draft plans can be committed' });

    // 2. Fetch selected items
    console.log(`[Optimization] Step 2: Fetching selected items...`);
    const { data: selectedItems } = await supabase
      .from('dispatch_plan_items')
      .select('cluster_id')
      .eq('dispatch_plan_id', id)
      .eq('is_selected', true);
      
    const clusterIds = (selectedItems || []).map(i => i.cluster_id);
    
    // 3. Dispatch the clusters
    console.log(`[Optimization] Step 3: Dispatching ${clusterIds.length} clusters...`);
    let tasks = [];
    let assignments = [];
    let optimization_run = null;
    if (clusterIds.length > 0) {
      tasks = await dispatchClusters(clusterIds, req.user.id);
      
      // 3.1 Load crews and assign intelligently
      console.log(`[Optimization] Step 3.1: Loading field crews and assigning ${tasks.length} tasks...`);
      const crews = await loadFieldCrews();
      const depot = await getDepot();
      assignments = await assignTasksToCrews(tasks, crews, depot);
      
      // 3.2 Apply assignments directly to the tasks
      console.log(`[Optimization] Step 3.2: Applying assignments...`);
      for (const assignment of assignments) {
        const crew = crews.find(c => c.id === assignment.crew_id);
        const memberIds = crew ? (crew.member_profile_ids || []) : [];
        
        if (assignment.task_ids_ordered.length > 0) {
          await supabase
            .from('cleanup_tasks')
            .update({
              assigned_crew_ids: memberIds,
              assigned_at: new Date().toISOString(),
              assigned_by: req.user.id,
              last_assigned_at: new Date().toISOString()
            })
            .in('id', assignment.task_ids_ordered);
        }
      }

      // 3.3 Create Optimization Run (for frontend route rendering)
      console.log(`[Optimization] Step 3.3: Creating Optimization Run...`);
      const { data: run, error: runError } = await supabase
        .from('optimization_runs')
        .insert({
          triggered_by: req.user.id,
          status: 'approved',
          approved_by: req.user.id,
          approved_at: new Date().toISOString(),
          criteria: {},
          num_tasks_optimized: tasks.length,
          num_crews: crews.length,
          weather_condition,
          traffic_condition
        })
        .select()
        .single();
        
      if (runError) throw runError;
      optimization_run = run;

      // 3.4 Generate and Save Routes
      console.log(`[Optimization] Step 3.4: Generating routes for ${assignments.length} crews...`);
      for (const assignment of assignments) {
        if (assignment.task_ids_ordered.length === 0) continue;
        
        const rawRoute = await generateRouteForCrew(
          assignment.crew_id,
          assignment.task_ids_ordered,
          depot,
          'none' // Defers to distance.provider.js default (haversine)
        );
        
        const { data: crewRoute, error: crewRouteError } = await supabase
          .from('crew_routes')
          .insert({
            optimization_run_id: run.id,
            crew_id: assignment.crew_id,
            start_depot: `POINT(${depot.longitude} ${depot.latitude})`,
            end_depot: `POINT(${depot.longitude} ${depot.latitude})`,
            total_distance_meters: rawRoute.totalDistance,
            total_duration_min: rawRoute.totalTime,
            task_count: assignment.task_ids_ordered.length
          })
          .select()
          .single();
          
        if (crewRouteError) throw crewRouteError;
        
        if (rawRoute.waypoints.length > 0) {
          const waypointsData = rawRoute.waypoints.map(wp => ({
            ...wp,
            crew_route_id: crewRoute.id
          }));
          await supabase.from('route_waypoints').insert(waypointsData);
        }
        
        for (let i = 0; i < assignment.task_ids_ordered.length; i++) {
          await supabase
            .from('cleanup_tasks')
            .update({
              crew_route_id: crewRoute.id,
              sequence_in_route: i + 1,
              // Update duration to include accurate routing travel time
              estimated_duration_min: rawRoute.waypoints.find(w => w.cleanup_task_id === assignment.task_ids_ordered[i])?.estimated_time_from_previous_min
            })
            .eq('id', assignment.task_ids_ordered[i]);
        }
      }
    }

    // 4. Update plan status
    console.log(`[Optimization] Plan committed successfully!`);
    await supabase.from('dispatch_plans').update({ status: 'approved' }).eq('id', id);

    res.status(200).json({ message: `Committed plan, created and assigned ${tasks.length} task(s)`, tasks, assignments, optimization_run });
  } catch (error) { next(error); }
};

// Phase 8 + 9 implementation - Now upgraded to Phase 1-6 Capacity Aware Pipeline seamlessly!
export const runOptimization = async (req, res, next) => {
  const { weather_condition = 'normal', traffic_condition = 'low' } = req.body;

  try {
    console.log(`[Optimization] Run initiated by user ${req.user?.id || 'admin'}`);
    console.log(`[Optimization] Conditions: Weather=${weather_condition}, Traffic=${traffic_condition}`);
    
    const depot = await getDepot();

    // 1. Prioritize backlog (Phase 1 & 2)
    console.log(`[Optimization] Prioritizing backlog...`);
    await prioritizeBacklog();

    // 2. Capacity-Aware Auto-Planner (Phase 3)
    console.log(`[Optimization] Generating capacity-aware dispatch plan...`);
    const { plan, selectedCount } = await generateDispatchPlan(req.user?.id || null);
    
    if (selectedCount === 0) {
      console.log(`[Optimization] Aborting: No capacity or no tasks available.`);
      return res.status(200).json({ message: 'No new tasks needed optimization', tasks: [] });
    }

    // Extract selected clusters from the plan
    const { data: items } = await supabase
      .from('dispatch_plan_items')
      .select('cluster_id')
      .eq('dispatch_plan_id', plan.id)
      .eq('is_selected', true);
      
    const clusterIds = items.map(i => i.cluster_id);

    // 3. Dispatch Clusters to Tasks (Phase 4)
    console.log(`[Optimization] Generating tasks for ${clusterIds.length} selected clusters...`);
    const tasks = await dispatchClusters(clusterIds, req.user?.id || null);

    // 4. Load field crews
    console.log(`[Optimization] Finding available field crews...`);
    const crews = await loadFieldCrews();

    // 5. Assign tasks to crews
    console.log(`[Optimization] Executing capacity-aware greedy assignment...`);
    const assignments = await assignTasksToCrews(tasks, crews, depot);

    // 6. Create optimization_run record (so UI can read it)
    console.log(`[Optimization] Saving optimization proposal...`);
    const { data: run, error } = await supabase
      .from('optimization_runs')
      .insert({
        triggered_by: req.user?.id,
        status: 'proposed',
        criteria: { info: 'Generated via Capacity-Aware Pipeline' },
        weather_condition,
        traffic_condition,
        num_tasks_optimized: tasks.length,
        num_crews: crews.length
      })
      .select()
      .single();

    if (error) throw error;

    // 7. Generate routes and save to DB (Phase 5)
    console.log(`[Optimization] Generating simulated routes...`);
    for (const assignment of assignments) {
      if (assignment.task_ids_ordered.length === 0) continue;

      const rawRoute = await generateRouteForCrew(
        assignment.crew_id,
        assignment.task_ids_ordered,
        depot,
        'none' // distance.provider.js default
      );

      const { data: crewRoute, error: crewRouteError } = await supabase
        .from('crew_routes')
        .insert({
          optimization_run_id: run.id,
          crew_id: assignment.crew_id,
          start_depot: `POINT(${depot.longitude} ${depot.latitude})`,
          end_depot: `POINT(${depot.longitude} ${depot.latitude})`,
          total_distance_meters: rawRoute.totalDistance,
          total_duration_min: rawRoute.totalTime,
          task_count: assignment.task_ids_ordered.length
        })
        .select()
        .single();
        
      if (crewRouteError) throw crewRouteError;

      if (rawRoute.waypoints.length > 0) {
        const waypointsData = rawRoute.waypoints.map(wp => ({
          ...wp,
          crew_route_id: crewRoute.id
        }));
        await supabase.from('route_waypoints').insert(waypointsData);
      }

      for (let i = 0; i < assignment.task_ids_ordered.length; i++) {
        await supabase
          .from('cleanup_tasks')
          .update({
            crew_route_id: crewRoute.id,
            sequence_in_route: i + 1,
            estimated_duration_min: rawRoute.waypoints.find(w => w.cleanup_task_id === assignment.task_ids_ordered[i])?.estimated_time_from_previous_min
          })
          .eq('id', assignment.task_ids_ordered[i]);
      }
    }

    return res.status(200).json({
      message: 'Optimization proposal generated',
      optimization_run: run,
      assignments,
      simulation: {
        weather: weatherSim,
        traffic: trafficSim
      }
    });
  } catch (error) { 
    console.error('[Optimization] FATAL ERROR during optimization:', error);
    next(error); 
  }
};

// Phase 9 implementation
export const approveOptimization = async (req, res, next) => {
  const { id } = req.params;
  
  try {
    // 1. Verify run
    const { data: run, error: runError } = await supabase
      .from('optimization_runs')
      .select('status')
      .eq('id', id)
      .single();
      
    if (runError) throw runError;
    if (run.status !== 'proposed') {
      return res.status(400).json({ message: 'Can only approve proposed optimization runs' });
    }
    
    // 2. Approve run
    const { data: updatedRun, error: updateError } = await supabase
      .from('optimization_runs')
      .update({
        status: 'approved',
        approved_by: req.user.id,
        approved_at: new Date().toISOString()
      })
      .eq('id', id)
      .select()
      .single();
      
    if (updateError) throw updateError;
    
    // 3. Update tasks and send notifications
    const { data: crewRoutes } = await supabase
      .from('crew_routes')
      .select('*, field_crews(member_profile_ids)')
      .eq('optimization_run_id', id);

    for (const route of (crewRoutes || [])) {
      const crewMembers = route.field_crews?.member_profile_ids || [];
      
      const { data: waypoints } = await supabase
        .from('route_waypoints')
        .select('cleanup_task_id')
        .eq('crew_route_id', route.id)
        .eq('waypoint_type', 'task');

      const taskIds = waypoints.map(wp => wp.cleanup_task_id);
      
      if (taskIds.length > 0) {
        await supabase
          .from('cleanup_tasks')
          .update({
            assigned_crew_ids: crewMembers,
            assigned_at: new Date().toISOString(),
            assigned_by: req.user.id,
            last_assigned_at: new Date().toISOString()
          })
          .in('id', taskIds);
      }
    }
    
    res.status(200).json({ message: 'Optimization approved', run: updatedRun });
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
        .select('*')
        .in('crew_route_id', routeIds)
        .order('sequence_order', { ascending: true });
        
      for (const route of routes) {
        route.waypoints = (waypoints || []).filter(w => w.crew_route_id === route.id);
      }
    }

    res.json({ ...run, routes: routes || [] });
  } catch (error) { next(error); }
};

// Get active (approved) routes
export const getActiveRoutes = async (req, res, next) => {
  try {
    // Find the most recent approved run
    const { data: run } = await supabase
      .from('optimization_runs')
      .select('id')
      .eq('status', 'approved')
      .order('approved_at', { ascending: false })
      .limit(1)
      .single();

    if (!run) return res.json({ routes: [] });

    const { data: routes } = await supabase
      .from('crew_routes')
      .select('*, field_crews(name)')
      .eq('optimization_run_id', run.id);

    for (const route of (routes || [])) {
      const { data: waypoints } = await supabase
        .from('route_waypoints')
        .select('*')
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
    const { data, error } = await supabase
      .from('field_crews')
      .select('*')
      .order('name');

    if (error) return res.status(400).json({ message: 'Failed to fetch crews' });
    res.json(data);
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
export const updateFieldCrew = async (req, res, next) => {
  const { id } = req.params;
  const { shift_start, shift_end, max_tasks_per_shift } = req.body;

  try {
    const updateData = { updated_at: new Date().toISOString() };
    if (shift_start !== undefined) updateData.shift_start = shift_start;
    if (shift_end !== undefined) updateData.shift_end = shift_end;
    if (max_tasks_per_shift !== undefined) updateData.max_tasks_per_shift = parseInt(max_tasks_per_shift);

    const { data, error } = await supabase
      .from('field_crews')
      .update(updateData)
      .eq('id', id)
      .select()
      .single();

    if (error) return res.status(400).json({ message: 'Failed to update crew', error: error.message });
    res.json(data);
  } catch (error) { next(error); }
};

// Phase 6: Field Feedback Loop
export const completeTask = async (req, res, next) => {
  const { id } = req.params;
  const { outcome, notes } = req.body;
  
  if (!outcome) {
    return res.status(400).json({ message: 'Outcome is required' });
  }

  try {
    const updatedTask = await processTaskFeedback(id, outcome, notes, req.user?.id);
    res.status(200).json({ 
      message: 'Task completed and clusters updated successfully', 
      task: updatedTask 
    });
  } catch (error) { next(error); }
};

