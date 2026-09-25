import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { getDistanceAndDuration } from '../providers/distance.provider.js';
import { getTomTomDistanceMatrix } from '../providers/tomtom.provider.js';
import { solveVRPWithOrTools } from './ortools.service.js';

/**
 * Extracts lat/lng from a WKB hex string (used for cluster center_point)
 */
function parseWkbPoint(wkbString) {
  // Simple heuristic for getting lat/lng without wkx library in backend
  // In a real app we'd use a GIS library, but we can query PostGIS via Supabase RPC
  // For this assignment we can fetch it during the location lookup
  return null; 
}

/**
 * Gets the lat/lng location for a task (from its cluster)
 */
export async function getTaskLocation(taskId) {
  const { data: task } = await supabase
    .from('cleanup_tasks')
    .select('id, cluster_id, is_custom, report_ids')
    .eq('id', taskId)
    .single();
    
  if (task && task.cluster_id) {
    const { data: cluster } = await supabase
      .from('clusters')
      .select('center')
      .eq('id', task.cluster_id)
      .single();
      
    if (cluster && cluster.center && cluster.center.coordinates) {
      return { lat: cluster.center.coordinates[1], lng: cluster.center.coordinates[0] };
    }
  } 
  
  // Custom tasks or fallback
  const reportIds = task?.report_ids || [];
  if (reportIds.length > 0) {
    const { data: report } = await supabase
      .from('reports')
      .select('location')
      .eq('id', reportIds[0])
      .single();
      
    if (report && report.location && report.location.coordinates) {
      return { lat: report.location.coordinates[1], lng: report.location.coordinates[0] };
    }
  }
  
  // Default to PLP if everything fails
  return { lat: 14.561433, lng: 121.075636 };
}

/**
 * Assigns tasks to crews using greedy nearest-neighbor approach
 */
export async function assignTasksToCrews(tasks, crews, depot) {
  if (tasks.length === 0 || crews.length === 0) return [];

  // Phase 2 Upgrade: Google OR-Tools VRP Integration
  // 1. Gather all coordinates (Depot is index 0)
  const coordinates = [{ lat: depot.latitude, lng: depot.longitude }];
  const taskMapping = []; // Maps index (1 to N) back to task object
  
  for (const task of tasks) {
    const loc = await getTaskLocation(task.id);
    coordinates.push(loc);
    taskMapping.push(task);
  }

  // 2. Fetch Distance Matrix from TomTom
  let distanceMatrix = [];
  try {
    console.log(`[Optimization] Fetching TomTom Matrix for ${coordinates.length} points...`);
    distanceMatrix = await getTomTomDistanceMatrix(coordinates);
  } catch (err) {
    console.error('[Optimization] TomTom Matrix failed, falling back to Haversine Matrix:', err.message);
    // Fallback: manually build haversine matrix
    distanceMatrix = [];
    for (let i = 0; i < coordinates.length; i++) {
      const row = [];
      for (let j = 0; j < coordinates.length; j++) {
        const { duration_min } = await getDistanceAndDuration(
          coordinates[i].lat, coordinates[i].lng,
          coordinates[j].lat, coordinates[j].lng,
          'haversine'
        );
        // OR-Tools works best with integers, convert minutes to seconds
        row.push(Math.round(duration_min * 60));
      }
      distanceMatrix.push(row);
    }
  }

  // 3. Solve VRP with OR-Tools
  let routes = [];
  try {
    console.log(`[Optimization] Solving VRP for ${crews.length} vehicles...`);
    routes = await solveVRPWithOrTools(distanceMatrix, crews.length);
  } catch (err) {
    console.error('[Optimization] OR-Tools failed, falling back to old Greedy Algorithm:', err.message);
    // We should implement a fallback here or throw
    throw err;
  }

  // 4. Map routes back to crews and tasks
  const results = [];
  for (let i = 0; i < crews.length; i++) {
    const crew = crews[i];
    const routeIndices = routes[i] || [];
    
    const orderedTasks = [];
    // Skip depot (index 0) if it's in the route
    for (const nodeIndex of routeIndices) {
      if (nodeIndex === 0) continue;
      // nodeIndex - 1 maps to the task in taskMapping
      const task = taskMapping[nodeIndex - 1];
      if (task) {
        orderedTasks.push(task.id);
      }
    }

    results.push({
      crew_id: crew.id,
      task_ids_ordered: orderedTasks,
      total_estimated_tasks: orderedTasks.length
    });
  }

  return results;
}
