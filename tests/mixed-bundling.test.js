import { groupClustersForTask, groupReportsForSweeper } from '../src/modules/optimization/services/taskGrouping.js';
import { bestSatelliteOrder, openInsertionMinutes, provisionalAnchorSuccessors } from '../src/modules/optimization/services/geoTime.js';
import { bundleReports } from '../src/modules/optimization/services/bundler.js';

const at = (lat, lng = 121) => ({ lat, lng });
const crew = { starting_volume_m3: 1, starting_weight_kg: 50, max_volume_m3: 3, max_weight_kg: 500 };
const groups = [{ group_key: 'cluster:a', centre: at(14), successorCentre: at(14.03),
  estimated_volume_m3: 0.2, estimated_weight_kg: 20, crew }];
const settings = { mixed_spatial_buffer_meters: 1500, mixed_max_reports_per_anchor: 5,
  mixed_max_detour_minutes: 30, solver_max_candidate_nodes: 20, bundle_proximity_bonus_max: 15,
  depot: at(14.03) };
const report = (id, lat, extras = {}) => ({ id, location: at(lat), lifecycle_state: 'maturing',
  created_at: '2026-10-08T00:00:00Z', base_priority_score: 70,
  estimated_volume_m3: 0.1, estimated_weight_kg: 10, ...extras });

test('200 m cluster grouping and 100 m Sweeper grouping are deterministic', () => {
  const clusters = [
    { id: 'b', centre: at(14.001), reportIds: ['r2'], effortMinutes: 20, priority_score: 60 },
    { id: 'far', centre: at(14.01), reportIds: ['r3'], effortMinutes: 10, priority_score: 20 },
    { id: 'a', centre: at(14), reportIds: ['r1'], effortMinutes: 30, priority_score: 90 }
  ];
  expect(groupClustersForTask(clusters)).toMatchObject([
    { group_key: 'cluster:a', clusterIds: ['a', 'b'], reportIds: ['r1', 'r2'], effortMinutes: 50 },
    { group_key: 'cluster:far' }
  ]);
  expect(groupReportsForSweeper([report('r2', 14.0005), report('r1', 14)], { radiusM: 100, maxPerTask: 2 })[0].reportIds).toEqual(['r1', 'r2']);
});

test('open insertion uses the assigned successor and chooses a stable order', () => {
  const matrix = (a, b) => ({ A: { B: 10, S1: 3, S2: 7 }, S1: { S2: 2, B: 6 }, S2: { S1: 2, B: 2 } })[a.id]?.[b.id] ?? 0;
  const A = { id: 'A' }, B = { id: 'B' }, S1 = { id: 'S1' }, S2 = { id: 'S2' };
  expect(openInsertionMinutes(A, [S1, S2], B, matrix)).toBe(0);
  expect(bestSatelliteOrder(A, [S2, S1], B, matrix).satellites.map(item => item.id)).toEqual(['S1', 'S2']);
});

test('provisional successor is the next nearest anchor on the same crew route', () => {
  const assigned = [
    { group_key: 'a', planned_crew_id: 'crew', centre: at(14.001) },
    { group_key: 'b', planned_crew_id: 'crew', centre: at(14.003) },
    { group_key: 'other', planned_crew_id: 'another', centre: at(14.002) }
  ];
  const successors = provisionalAnchorSuccessors(assigned, at(14));
  expect(successors.get('a')).toEqual(at(14.003));
  expect(successors.get('b')).toEqual(at(14));
  expect(successors.get('other')).toEqual(at(14));
});

test('tier-first ranking preserves base score and records bounded rejections', () => {
  const result = bundleReports({ groups, candidates: [
    report('ordinary', 14.001, { base_priority_score: 95 }),
    report('breached', 14.002, { lifecycle_state: 'sla_breached', base_priority_score: 10 }),
    report('hazard', 14.001, { hazard_class: 'suspected_hazard' }),
    report('far', 14.08),
    report('heavy', 14.001, { estimated_volume_m3: 5 })
  ], settings, workMinutes: () => 10, remainingMinutes: 100 });
  const assigned = result.assignments[0].satellites.map(item => item.report.id);
  expect(assigned.slice(0, 2)).toEqual(['breached', 'ordinary']);
  expect(result.assignments[0].satellites[0].report.base_priority_score).toBe(10);
  expect(Object.fromEntries(result.rejected.map(item => [item.report_id, item.reason]))).toMatchObject({
    hazard: 'hazard_review', far: 'outside_buffer', heavy: 'cap_volume'
  });
});

test('provisional detour and candidate-node caps fail closed', () => {
  const result = bundleReports({ groups, candidates: [report('near', 14.003, { location: at(14.003, 121.005), base_priority_score: 100 }), report('next', 14.004, { base_priority_score: 20 })],
    settings: { ...settings, mixed_max_detour_minutes: 0, solver_max_candidate_nodes: 2 },
    workMinutes: () => 10, remainingMinutes: 100 });
  expect(result.rejected).toEqual(expect.arrayContaining([
    { report_id: 'near', reason: 'cap_detour' },
    { report_id: 'next', reason: 'deferred_by_compute_limit' }
  ]));
});
