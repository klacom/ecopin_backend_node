import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

// Haversine distance in meters
function haversineDistance(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const phi1 = lat1 * Math.PI / 180;
  const phi2 = lat2 * Math.PI / 180;
  const deltaPhi = (lat2 - lat1) * Math.PI / 180;
  const deltaLam = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(deltaPhi/2)**2 + Math.cos(phi1) * Math.cos(phi2) * Math.sin(deltaLam/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
}

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
  
  // 1. Sort tasks by priority descending
  const sortedTasks = [...tasks].sort((a, b) => b.priority_score - a.priority_score);
  
  // 2. Initialize crew buckets
  const crewAssignments = crews.map(c => ({
    crew_id: c.id,
    crew: c,
    tasks: [], // Store full task object temporarily
    max_tasks: c.max_tasks_per_shift || 10
  }));
  
  // 3. Alternating assignment based on priority
  for (let i = 0; i < sortedTasks.length; i++) {
    const task = sortedTasks[i];
    
    // Find crew with fewest tasks that hasn't hit its max limit
    let bestCrew = null;
    let minTasks = Infinity;
    
    // To ensure alternating pattern for identical task counts (Crew A gets 1st, Crew B gets 2nd)
    for (let j = 0; j < crewAssignments.length; j++) {
      const ca = crewAssignments[j];
      if (ca.tasks.length < ca.max_tasks && ca.tasks.length < minTasks) {
        minTasks = ca.tasks.length;
        bestCrew = ca;
      }
    }
    
    if (bestCrew) {
      bestCrew.tasks.push(task);
    } else {
      // All crews hit max tasks, stop assigning
      break;
    }
  }
  
  // 4. Order tasks within each crew by nearest neighbor
  const results = [];
  
  for (const ca of crewAssignments) {
    if (ca.tasks.length === 0) {
      results.push({
        crew_id: ca.crew_id,
        task_ids_ordered: [],
        total_estimated_tasks: 0
      });
      continue;
    }
    
    const orderedTasks = [];
    let currentLat = depot.latitude;
    let currentLng = depot.longitude;
    const remainingTasks = [...ca.tasks];
    
    // Pre-fetch locations for all tasks assigned to this crew
    const taskLocations = {};
    for (const t of remainingTasks) {
      taskLocations[t.id] = await getTaskLocation(t.id);
    }
    
    while (remainingTasks.length > 0) {
      let nearestIdx = 0;
      let minDistance = Infinity;
      
      for (let i = 0; i < remainingTasks.length; i++) {
        const t = remainingTasks[i];
        const loc = taskLocations[t.id];
        const dist = haversineDistance(currentLat, currentLng, loc.lat, loc.lng);
        
        if (dist < minDistance) {
          minDistance = dist;
          nearestIdx = i;
        }
      }
      
      const nearestTask = remainingTasks.splice(nearestIdx, 1)[0];
      orderedTasks.push(nearestTask.id);
      
      const nextLoc = taskLocations[nearestTask.id];
      currentLat = nextLoc.lat;
      currentLng = nextLoc.lng;
    }
    
    results.push({
      crew_id: ca.crew_id,
      task_ids_ordered: orderedTasks,
      total_estimated_tasks: orderedTasks.length
    });
  }
  
  return results;
}
