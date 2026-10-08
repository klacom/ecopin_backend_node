import { describe, expect, test } from '@jest/globals';
import { generateMixedRoutesFromProposal } from '../src/modules/optimization/services/routeGenerator.service.js';

const crew = { id: 'crew', speed_factor: 1, service_time_factor: 1 };
const depot = { lat: 14, lng: 121 };
const proposal = {
  routes: [{ vehicle_id: 'crew', stops: [{ task_id: 'cluster:a' }, { task_id: 'satellite:r1' }] }],
  node_ids: ['crew', 'cluster:a', 'satellite:r1'],
  task_locations: { 'cluster:a': { lat: 14.001, lng: 121.001 }, 'satellite:r1': { lat: 14.002, lng: 121.002 } },
  travel_time_matrix_min: [[0, 10, 10], [10, 0, 3], [10, 3, 0]]
};

describe('saved Mixed route proposal', () => {
  test('keeps the solver stop order and expands the retained satellite', () => {
    const routes = generateMixedRoutesFromProposal(proposal,
      [{ group_key: 'cluster:a', task_id: 'task-a', crew_id: 'crew', satellite_report_ids: ['r1'] }],
      [crew], depot, 4);
    expect(routes).toHaveLength(1);
    expect(routes[0].task_ids).toEqual(['task-a']);
    expect(routes[0].waypoints.map(point => point.waypoint_type)).toEqual([
      'depot_start', 'task', 'bundled_report', 'depot_end'
    ]);
    expect(routes[0].waypoints[2].report_id).toBe('r1');
  });

  test('omits a stale optional satellite without losing its anchor', () => {
    const routes = generateMixedRoutesFromProposal(proposal,
      [{ group_key: 'cluster:a', task_id: 'task-a', crew_id: 'crew', satellite_report_ids: [] }],
      [crew], depot, 4);
    expect(routes[0].waypoints.map(point => point.waypoint_type)).toEqual([
      'depot_start', 'task', 'depot_end'
    ]);
  });

  test('fails closed if retained satellites exceed the matrix detour cap', () => {
    expect(() => generateMixedRoutesFromProposal(proposal,
      [{ group_key: 'cluster:a', task_id: 'task-a', crew_id: 'crew', satellite_report_ids: ['r1'] }],
      [crew], depot, 2)).toThrow('detour_cap_exceeded');
  });
});
