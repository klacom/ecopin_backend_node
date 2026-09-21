import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

import { calculateClusterPriorities } from '../services/mcdaPrioritizer.service.js';
import { mapClustersToTasks } from '../services/clusterTaskMapper.service.js';
import { assignTasksToCrews } from '../services/crewAssigner.service.js';
import { generateRouteForCrew } from '../services/routeGenerator.service.js';
import { applyWeatherSimulation } from '../services/weatherSimulator.service.js';
import { applyTrafficSimulation } from '../services/trafficSimulator.service.js';

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

// Phase 8 + 9 implementation
export const runOptimization = async (req, res, next) => {
  const { weather_condition = 'normal', traffic_condition = 'low' } = req.body;

  try {
    // 1. Load MCDA weights and depot
    console.log(`[Optimization] Run initiated by user ${req.user.id}`);
    console.log(`[Optimization] Conditions: Weather=${weather_condition}, Traffic=${traffic_condition}`);
    const weights = await loadWeights();
    const depot = await getDepot();

    // 2. Find eligible clusters
    console.log(`[Optimization] Scanning for unresolved clusters...`);
    const eligibleClusters = await findEligibleClusters();
    console.log(`[Optimization] Found ${eligibleClusters.length} eligible cluster(s).`);

    if (eligibleClusters.length === 0) {
      console.log(`[Optimization] Aborting: No clusters require optimization.`);
      return res.status(200).json({ message: 'No clusters require optimization', tasks: [] });
    }

    // 3. Calculate priorities
    console.log(`[Optimization] Calculating MCDA priority scores for clusters...`);
    const prioritizedClusters = await calculateClusterPriorities(
      eligibleClusters.map(c => c.id), weather_condition, weights
    );
    console.log(`[Optimization] Prioritization complete.`);

    // 4. Create/identify cleanup tasks (Limit to top 50 to prevent timeouts)
    console.log(`[Optimization] Mapping top clusters to cleanup tasks...`);
    const tasks = await mapClustersToTasks(prioritizedClusters.slice(0, 50));
    console.log(`[Optimization] Generated ${tasks.length} cleanup task(s).`);
    
    if (tasks.length === 0) {
      console.log(`[Optimization] Aborting: No new tasks needed optimization.`);
      return res.status(200).json({ message: 'No new tasks needed optimization', tasks: [] });
    }

    // 5. Load field crews
    console.log(`[Optimization] Finding available field crews...`);
    const crews = await loadFieldCrews();
    console.log(`[Optimization] Found ${crews.length} available crew(s).`);

    // 6. Assign tasks to crews
    console.log(`[Optimization] Executing greedy assignment algorithm...`);
    const assignments = await assignTasksToCrews(tasks, crews, depot);
    console.log(`[Optimization] Task assignment complete.`);

    // 7. Create optimization_run record
    console.log(`[Optimization] Saving optimization proposal...`);
    const { data: run, error } = await supabase
      .from('optimization_runs')
      .insert({
        triggered_by: req.user.id,
        status: 'proposed',
        criteria: weights,
        weather_condition,
        traffic_condition,
        num_tasks_optimized: tasks.length,
        num_crews: crews.length
      })
      .select()
      .single();

    if (error) throw error;
    console.log(`[Optimization] Proposal saved with ID: ${run.id}`);

    // 8. Generate routes and save to DB
    console.log(`[Optimization] Generating simulated routes and calculating ETA...`);
    for (const assignment of assignments) {
      const rawRoute = await generateRouteForCrew(
        assignment.crew_id,
        assignment.task_ids_ordered,
        depot,
        'none' // default direction provider
      );

      // Apply traffic simulation
      const { adjustedWaypoints, simulation: trafficSim } = applyTrafficSimulation(rawRoute.waypoints, traffic_condition);
      
      const totalTime = adjustedWaypoints.reduce((sum, w) => sum + (w.estimated_time_from_previous_min || 0), 0);

      // Store crew_route
      const { data: crewRoute, error: crewRouteError } = await supabase
        .from('crew_routes')
        .insert({
          optimization_run_id: run.id,
          crew_id: assignment.crew_id,
          start_depot: depot,
          end_depot: depot,
          total_distance_meters: rawRoute.totalDistance,
          total_duration_min: totalTime,
          task_count: assignment.task_ids_ordered.length,
          weather_snapshot: applyWeatherSimulation([], weather_condition).simulation,
          traffic_snapshot: trafficSim
        })
        .select()
        .single();
        
      if (crewRouteError) throw crewRouteError;

      // Store waypoints
      if (adjustedWaypoints.length > 0) {
        const waypointsData = adjustedWaypoints.map(wp => ({
          ...wp,
          crew_route_id: crewRoute.id
        }));
        await supabase.from('route_waypoints').insert(waypointsData);
      }

      // Update tasks with route references
      for (let i = 0; i < assignment.task_ids_ordered.length; i++) {
        await supabase
          .from('cleanup_tasks')
          .update({
            crew_route_id: crewRoute.id,
            sequence_in_route: i + 1,
            estimated_duration_min: adjustedWaypoints.find(w => w.cleanup_task_id === assignment.task_ids_ordered[i])?.estimated_time_from_previous_min
          })
          .eq('id', assignment.task_ids_ordered[i]);
      }
    }

    const { simulation: weatherSim } = applyWeatherSimulation([], weather_condition);
    const { simulation: trafficSim } = applyTrafficSimulation([], traffic_condition);

    console.log(`[Optimization] Optimization pipeline completed successfully in ${Date.now() - (req._startTime || Date.now())}ms`);

    res.status(201).json({
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

