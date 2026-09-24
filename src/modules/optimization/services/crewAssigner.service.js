import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { getDistanceAndDuration } from '../providers/distance.provider.js';

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
  const crewAssignments = crews.map(c => {
    // Calculate available minutes based on shift, default 8 hours
    const sH = c.shift_start ? parseInt(c.shift_start.split(':')[0]) : 8;
    const sM = c.shift_start ? parseInt(c.shift_start.split(':')[1]) : 0;
    const eH = c.shift_end ? parseInt(c.shift_end.split(':')[0]) : 17;
    const eM = c.shift_end ? parseInt(c.shift_end.split(':')[1]) : 0;
    let totalMin = (eH * 60 + eM) - (sH * 60 + sM);
    if (totalMin < 0) totalMin += 24 * 60;
    
    return {
      crew_id: c.id,
      crew: c,
      tasks: [],
      assigned_minutes: 0,
      capacity_minutes: totalMin || 480
    };
  });
  
  // 3. Alternating assignment based on workload (estimated duration)
  for (let i = 0; i < sortedTasks.length; i++) {
    const task = sortedTasks[i];
    const estimatedTime = task.estimated_duration_min || 60;
    
    // Find crew with lowest workload that can fit this task
    let bestCrew = null;
    let minAssignedMinutes = Infinity;
    
    for (let j = 0; j < crewAssignments.length; j++) {
      const ca = crewAssignments[j];
      if (ca.assigned_minutes + estimatedTime <= ca.capacity_minutes && ca.assigned_minutes < minAssignedMinutes) {
        minAssignedMinutes = ca.assigned_minutes;
        bestCrew = ca;
      }
    }
    
    if (bestCrew) {
      bestCrew.tasks.push(task);
      bestCrew.assigned_minutes += estimatedTime;
    } else {
      // If it exceeds strict capacity but must be assigned, give it to the crew with the least work
      let fallbackCrew = crewAssignments[0];
      for (let j = 1; j < crewAssignments.length; j++) {
        if (crewAssignments[j].assigned_minutes < fallbackCrew.assigned_minutes) {
          fallbackCrew = crewAssignments[j];
        }
      }
      fallbackCrew.tasks.push(task);
      fallbackCrew.assigned_minutes += estimatedTime;
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
        const { distance_meters: dist } = await getDistanceAndDuration(currentLat, currentLng, loc.lat, loc.lng);
        
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
