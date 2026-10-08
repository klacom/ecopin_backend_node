import { getDistanceAndDuration } from '../providers/distance.provider.js';
export async function generateRouteForCrew(crewId, orderedTaskIds, depot, provider = 'haversine', { locations, speedFactor = 1, travelMode = 'DRIVING', signal, distance = getDistanceAndDuration } = {}) {
  if (!locations || !Number.isFinite(speedFactor) || speedFactor<=0) throw new Error('Verified task locations and speed factor required');
  const waypoints = [{ sequence_order: 0, latitude: depot.latitude, longitude: depot.longitude, cleanup_task_id: null,
    waypoint_type: 'depot_start', distance_from_previous_meters: 0, estimated_time_from_previous_min: 0 }];
  let previous = depot;
  let approximate = false;
  const stops = [...orderedTaskIds.map(id => {
    const location = locations.get(id);
    if (!location || !Number.isFinite(location.lat) || !Number.isFinite(location.lng)) throw new Error('Task location unavailable');
    return { latitude: location.lat, longitude: location.lng, id };
  }), { ...depot, id: null }];
  for (const stop of stops) {
    signal?.throwIfAborted();
    const leg = await distance(previous.latitude, previous.longitude, stop.latitude, stop.longitude, provider === 'none' ? 'haversine' : provider, signal, travelMode);
    approximate ||= leg.approximate === true;
    waypoints.push({ sequence_order: waypoints.length, latitude: stop.latitude, longitude: stop.longitude,
      cleanup_task_id: stop.id, waypoint_type: stop.id ? 'task' : 'depot_end', distance_from_previous_meters: Math.ceil(leg.distance_meters),
      estimated_time_from_previous_min: Math.ceil(leg.duration_min / speedFactor), polyline: leg.polyline ?? null });
    previous = stop;
  }
  return { crew_id: crewId, task_ids: orderedTaskIds, waypoints, approximate,
    totalDistance: waypoints.reduce((sum,w) => sum+w.distance_from_previous_meters,0),
    totalTime: waypoints.reduce((sum,w) => sum+w.estimated_time_from_previous_min,0) };
}
