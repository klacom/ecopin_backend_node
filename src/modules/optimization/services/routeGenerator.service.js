import { getDistanceAndDuration } from '../providers/distance.provider.js';
import { metresBetween } from './geoTime.js';
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

export function generateMixedRoutesFromProposal(proposal, commitResults, crews, depot, maxDetourMinutes) {
  if (!proposal || !Array.isArray(proposal.routes) || !Array.isArray(proposal.node_ids) ||
      !Array.isArray(proposal.travel_time_matrix_min)) throw new Error('Saved v5 route proposal required');
  const nodes = new Map(proposal.node_ids.map((id, index) => [id, index]));
  const committed = new Map(commitResults.filter(result => result.task_id).map(result => [result.group_key, result]));
  const crewById = new Map(crews.map(crew => [crew.id, crew]));
  const routes = [];
  for (const proposed of proposal.routes) {
    const crew = crewById.get(proposed.vehicle_id);
    if (!crew) throw new Error('Saved route names an unavailable crew');
    const kept = proposed.stops.filter(stop => {
      const key = stop.task_id.startsWith('satellite:') ?
        [...committed.keys()].find(group => committed.get(group).satellite_report_ids?.includes(stop.task_id.slice(10))) :
        stop.task_id;
      return key && committed.has(key) && committed.get(key).crew_id === crew.id;
    });
    if (!kept.length) continue;
    const taskIds = [];
    const waypoints = [{ sequence_order: 0, latitude: depot.lat, longitude: depot.lng,
      cleanup_task_id: null, report_id: null, waypoint_type: 'depot_start',
      distance_from_previous_meters: 0, estimated_time_from_previous_min: 0 }];
    let previousId = crew.id;
    for (const stop of kept) {
      const satellite = stop.task_id.startsWith('satellite:');
      const reportId = satellite ? stop.task_id.slice(10) : null;
      const result = satellite ? [...committed.values()].find(group => group.satellite_report_ids?.includes(reportId)) :
        committed.get(stop.task_id);
      if (!result) throw new Error('Solver stop has no committed group');
      const location = proposal.task_locations[stop.task_id];
      const fromIndex = nodes.get(previousId), toIndex = nodes.get(stop.task_id);
      if (fromIndex == null || toIndex == null || !location) throw new Error('Proposal matrix is incomplete');
      const previous = waypoints.at(-1);
      waypoints.push({ sequence_order: waypoints.length, latitude: location.lat, longitude: location.lng,
        cleanup_task_id: result.task_id, report_id: reportId,
        waypoint_type: satellite ? 'bundled_report' : 'task',
        distance_from_previous_meters: Math.ceil(metresBetween({ lat: previous.latitude, lng: previous.longitude }, location)),
        estimated_time_from_previous_min: Math.ceil(proposal.travel_time_matrix_min[fromIndex][toIndex] / Number(crew.speed_factor)) });
      if (!satellite) taskIds.push(result.task_id);
      previousId = stop.task_id;
    }
    const lastIndex = nodes.get(previousId), depotIndex = nodes.get(crew.id);
    const previous = waypoints.at(-1);
    waypoints.push({ sequence_order: waypoints.length, latitude: depot.lat, longitude: depot.lng,
      cleanup_task_id: null, report_id: null, waypoint_type: 'depot_end',
      distance_from_previous_meters: Math.ceil(metresBetween({ lat: previous.latitude, lng: previous.longitude }, depot)),
      estimated_time_from_previous_min: Math.ceil(proposal.travel_time_matrix_min[lastIndex][depotIndex] / Number(crew.speed_factor)) });
    for (const group of committed.values()) {
      if (group.crew_id !== crew.id || !group.satellite_report_ids?.length) continue;
      const retained = kept.map(stop => stop.task_id);
      const satellites = group.satellite_report_ids.map(id => `satellite:${id}`);
      if (!satellites.every(id => retained.includes(id))) throw new Error('Committed satellite missing from route proposal');
      const routeNodes = [crew.id, ...retained, crew.id];
      const directNodes = routeNodes.filter(id => !satellites.includes(id));
      const routeCost = ids => ids.slice(1).reduce((sum, id, index) => {
        const leg = proposal.travel_time_matrix_min[nodes.get(ids[index])]?.[nodes.get(id)];
        if (!Number.isFinite(leg)) throw new Error('Proposal matrix leg is missing');
        return sum + leg;
      }, 0) / Number(crew.speed_factor);
      const extra = Math.max(0, routeCost(routeNodes) - routeCost(directNodes));
      if (extra > maxDetourMinutes + 1e-6) throw new Error(`detour_cap_exceeded:${group.group_key}`);
    }
    routes.push({ crew_id: crew.id, task_ids: taskIds, waypoints,
      speed_factor: Number(crew.speed_factor), service_time_factor: Number(crew.service_time_factor),
      approximate: true, totalDistance: waypoints.reduce((sum, point) => sum + point.distance_from_previous_meters, 0),
      totalTime: waypoints.reduce((sum, point) => sum + point.estimated_time_from_previous_min, 0) });
  }
  const expected = new Set([...committed.values()].map(group => group.task_id));
  const actual = routes.flatMap(route => route.task_ids);
  if (actual.length !== expected.size || new Set(actual).size !== actual.length || actual.some(id => !expected.has(id)))
    throw new Error('Validated proposal does not cover every committed task');
  return routes;
}
