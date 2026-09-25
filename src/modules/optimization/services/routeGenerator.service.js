import { getTaskLocation } from './crewAssigner.service.js';
import { getDistanceAndDuration } from '../providers/distance.provider.js';

/**
 * Generate route waypoints for a crew's assigned tasks
 * @param {string} crewId 
 * @param {Array<string>} orderedTaskIds 
 * @param {Object} depot {latitude, longitude}
 * @param {string} provider 'none', 'ors', 'google'
 */
export async function generateRouteForCrew(crewId, orderedTaskIds, depot, provider = 'none') {
  const waypoints = [];

  // 1. Start with depot
  waypoints.push({
    sequence_order: 0,
    latitude: depot.latitude,
    longitude: depot.longitude,
    cleanup_task_id: null,
    waypoint_type: 'depot_start',
    distance_from_previous_meters: 0,
    estimated_time_from_previous_min: 0,
  });

  // 2. For each task in order, get its location
  let prevLat = depot.latitude, prevLng = depot.longitude;
  
  for (let i = 0; i < orderedTaskIds.length; i++) {
    const taskId = orderedTaskIds[i];
    const taskLocation = await getTaskLocation(taskId);
    
    // Use distance provider abstraction
    const { distance_meters: distance, duration_min: time, polyline } = await getDistanceAndDuration(
      prevLat, prevLng, taskLocation.lat, taskLocation.lng, provider === 'none' ? 'haversine' : provider
    );

    waypoints.push({
      sequence_order: i + 1,
      latitude: taskLocation.lat,
      longitude: taskLocation.lng,
      cleanup_task_id: taskId,
      waypoint_type: 'task',
      distance_from_previous_meters: Math.round(distance),
      estimated_time_from_previous_min: Math.round(time * 10) / 10,
      polyline: polyline || null
    });

    prevLat = taskLocation.lat;
    prevLng = taskLocation.lng;
  }
  
  // Optional: add depot_end waypoint if we want them to return to depot
  /*
  const returnDistance = haversineDistance(prevLat, prevLng, depot.latitude, depot.longitude);
  waypoints.push({
    sequence_order: orderedTaskIds.length + 1,
    latitude: depot.latitude,
    longitude: depot.longitude,
    cleanup_task_id: null,
    waypoint_type: 'depot_end',
    distance_from_previous_meters: Math.round(returnDistance),
    estimated_time_from_previous_min: Math.round((returnDistance / 833) * 10) / 10,
  });
  */

  // 3. Calculate totals
  const totalDistance = waypoints.reduce((sum, w) => sum + (w.distance_from_previous_meters || 0), 0);
  const totalTime = waypoints.reduce((sum, w) => sum + (w.estimated_time_from_previous_min || 0), 0);

  return { waypoints, totalDistance, totalTime };
}
