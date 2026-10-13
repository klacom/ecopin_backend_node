import { jest } from '@jest/globals';

const crewId = '00000000-0000-0000-0000-000000000030';
const clusterId = '00000000-0000-0000-0000-000000000200';
const reportId = '00000000-0000-0000-0000-000000000202';
const snapshot = { anchors: [{ id: clusterId, lat: 14, lng: 121, priority_score: 80,
  estimated_effort_minutes: 30, created_at: '2026-10-08T00:00:00Z',
  estimated_volume_m3: 0.3, estimated_weight_kg: 30,
  report_ids: ['00000000-0000-0000-0000-000000000201'] }],
satellites: [{ id: reportId, lat: 14.001, lng: 121.001, lifecycle_state: 'maturing',
  severity_score: 80, urgency_score: 3, issue_type: 'waste',
  created_at: '2026-10-08T00:00:00Z', sla_started_at: '2026-10-08T00:00:00Z',
  estimated_volume_m3: 0.1, estimated_weight_kg: 10, work_time_minutes: 10 }] };
const crew = { id: crewId, availability_status: 'available', supports_standard: true,
  supports_sweeper: true, member_profile_ids: ['member'], shift_start: '08:00', shift_end: '17:00',
  speed_factor: 1, service_time_factor: 1, max_tasks_per_shift: 10,
  max_volume_m3: 5, max_weight_kg: 1000, starting_volume_m3: 1, starting_weight_kg: 100,
  certifications: [], hazmat_certified: false };
const unstaffedCrew = { ...crew, id: '00000000-0000-0000-0000-000000000031',
  member_profile_ids: [], team_lead_profile_id: null };
const settingsRows = Object.entries({ swmo_depot: { latitude: 14, longitude: 121 },
  mixed_spatial_buffer_meters: 1500, mixed_max_reports_per_anchor: 5,
  mixed_max_detour_minutes: 30, solver_time_limit_seconds: 2,
  solver_max_candidate_nodes: 200, mixed_bundle_reserve_pct: 20,
  mcda_weights: { severity: 0.4, urgency: 0.25, report_count: 0.15, waiting_time: 0.15, weather: 0.05 } })
  .map(([key, value]) => ({ key, value }));
let saved;
let activeTasksMock = [];
const db = {
  from: table => ({ select: () => ({
    then: resolve => resolve({ data: table === 'optimization_settings' ? settingsRows : [], error: null }),
    eq: () => Promise.resolve({ data: table === 'field_crews' ? [crew, unstaffedCrew] : [], error: null }),
    not: () => Promise.resolve({ data: table === 'cleanup_tasks' ? activeTasksMock : [], error: null })
  }) }),
  rpc: async (name, args) => {
    if (name === 'mixed_planning_snapshot') return { data: snapshot, error: null };
    if (name === 'save_mixed_dispatch_draft') { saved = args; return { data: { id: 'plan-1' }, error: null }; }
    throw new Error(`Unexpected RPC ${name}`);
  }
};
const solve = jest.fn(async () => ({ contract_version: 'v5', status: 'success',
  routes: [{ vehicle_id: crewId, stops: [
    { task_id: `cluster:${clusterId}`, volume_after_m3: 1.3, weight_after_kg: 130 },
    { task_id: `satellite:${reportId}`, volume_after_m3: 1.4, weight_after_kg: 140 }
  ] }], unassigned: [], solver_diagnostics: { elapsed_seconds: 1 } }));
const matrix = jest.fn(async points => points.map((_, i) => points.map((_, j) =>
  i === j ? 0 : i === 0 || j === 0 ? 600 : 180)));
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: db }));
jest.unstable_mockModule('../src/modules/optimization/services/workQueue.service.js', () => ({ prioritizeBacklog: jest.fn(async () => []) }));
jest.unstable_mockModule('../src/modules/optimization/providers/tomtom.provider.js', () => ({ getTomTomDistanceMatrix: matrix }));
jest.unstable_mockModule('../src/modules/optimization/services/ortools.service.js', () => ({ solveVRPWithOrTools: solve }));
const { generateMixedDispatchPlan } = await import('../src/modules/optimization/services/mixedPlanner.service.js');

test('one bounded solve creates a draft with distinct anchored satellites and load snapshots', async () => {
  const result = await generateMixedDispatchPlan('officer', { mode: 'mixed', break_duration_min: 60,
    overtime_tolerance_min: 15, max_tasks_per_shift: 15, capacity_utilization: 1 },
  { jobId: 'job-1', workerToken: 'worker-1' });
  expect(result.plan.id).toBe('plan-1');
  expect(saved.capacity.generalist).toMatchObject({ crews: 1, minutes: 495 });
  expect(saved.capacity.availableCrews).toBe(1);
  expect(saved.items[0].estimated_duration_minutes).toBe(55);
  expect(saved.items.map(item => ({ type: item.item_type, selected: item.is_selected, reason: item.reason })))
    .toEqual([{ type: 'cluster', selected: true, reason: 'selected' },
      { type: 'bundled_report', selected: true, reason: 'selected' }]);
  expect(solve).toHaveBeenCalledTimes(1);
  const payload = solve.mock.calls[0][0];
  expect(payload.options.solver_time_limit_seconds).toBe(2);
  expect(payload.tasks.map(task => task.id)).toEqual([`cluster:${clusterId}`, `satellite:${reportId}`]);
  expect(payload.tasks[1].anchor_id).toBe(payload.tasks[0].id);
  expect(saved.items.filter(item => item.is_selected)).toHaveLength(2);
  expect(saved.items[1].load_snapshot).toEqual({ volume_m3: 1.4, weight_kg: 140 });
  expect(saved.proposal.node_ids).toEqual([crewId, `cluster:${clusterId}`, `satellite:${reportId}`]);
  expect(matrix).toHaveBeenCalledTimes(1);
});

test('solver-dropped work does not consume displayed draft capacity', async () => {
  solve.mockImplementationOnce(async payload => ({ contract_version: 'v5', status: 'success',
    routes: [{ vehicle_id: crewId, stops: [] }],
    unassigned: payload.tasks.map(task => ({ task_id: task.id, reason: 'unknown_load' })),
    solver_diagnostics: { candidate_nodes: payload.tasks.length } }));
  await generateMixedDispatchPlan('officer', { mode: 'mixed' },
    { jobId: 'job-dropped', workerToken: 'worker-dropped' });
  expect(saved.items.every(item => !item.is_selected)).toBe(true);
  expect(saved.capacity.used).toBe(0);
  expect(saved.capacity.generalist.used).toBe(0);
});

test('unused Mixed reserve admits an unselected anchor in the same solver call', async () => {
  const extraId = '00000000-0000-0000-0000-000000000300';
  const originalEffort = snapshot.anchors[0].estimated_effort_minutes;
  const originalSatellites = snapshot.satellites;
  snapshot.anchors[0].estimated_effort_minutes = 200;
  snapshot.anchors.push({ ...snapshot.anchors[0], id: extraId, lat: 14.01,
    priority_score: 70, report_ids: ['00000000-0000-0000-0000-000000000301'] });
  snapshot.satellites = [];
  solve.mockImplementationOnce(async payload => ({ contract_version: 'v5', status: 'success',
    routes: [{ vehicle_id: crewId, stops: payload.tasks.map(task => ({ task_id: task.id,
      volume_after_m3: 1.3, weight_after_kg: 130 })) }],
    unassigned: [], solver_diagnostics: { elapsed_seconds: 1 } }));
  try {
    await generateMixedDispatchPlan('officer', { mode: 'mixed' },
      { jobId: 'job-2', workerToken: 'worker-2' });
    expect(solve.mock.lastCall[0].tasks.map(task => task.id)).toEqual([
      `cluster:${clusterId}`, `cluster:${extraId}`]);
    expect(saved.items.filter(item => item.is_selected).map(item => item.group_key)).toEqual([
      `cluster:${clusterId}`, `cluster:${extraId}`]);
  } finally {
    snapshot.anchors.pop();
    snapshot.anchors[0].estimated_effort_minutes = originalEffort;
    snapshot.satellites = originalSatellites;
  }
});

test('TomTom Matrix provider failure triggers resilient geometric fallback without failing plan', async () => {
  const warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});
  try {
    matrix.mockRejectedValueOnce(new Error('TomTom 503 Service Unavailable'));
    const result = await generateMixedDispatchPlan('officer', { mode: 'mixed' },
      { jobId: 'job-fallback', workerToken: 'worker-fallback' });
    expect(result.plan.id).toBe('plan-1');
    expect(result.diagnostics.matrix_fallback_used).toBe(true);
    expect(saved.items.some(item => item.is_selected)).toBe(true);
    expect(saved.items[0]).toHaveProperty('status', 'scheduled');
    expect(saved.items[0]).toHaveProperty('operational_label', 'Scheduled for dispatch');
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('[MixedPlanner] TomTom Distance Matrix unavailable'),
      'TomTom 503 Service Unavailable'
    );
  } finally {
    warnSpy.mockRestore();
  }
});

test('rainy weather condition auto-scales service time by 1.15x buffer', async () => {
  const result = await generateMixedDispatchPlan('officer', { mode: 'mixed', weather_condition: 'rainy' },
    { jobId: 'job-rain', workerToken: 'worker-rain' });
  expect(result.plan.id).toBe('plan-1');
  expect(result.diagnostics.weather_adjustment).toEqual({ condition: 'rainy', multiplier: 1.15 });
  expect(saved.settings.weather_condition).toBe('rainy');
  expect(saved.settings.weather_multiplier).toBe(1.15);
  // Anchor effort: 30 * 1.15 = 35; travel: 25 -> duration: 60
  expect(saved.items[0].estimated_duration_minutes).toBe(60);
});

test('active tasks deduct remaining vehicle task capacity, time budget and physical load', async () => {
  activeTasksMock = [{
    assigned_field_crew_id: crewId,
    status: 'pending',
    estimated_duration_min: 116,
    estimated_volume_m3: 0.5,
    estimated_weight_kg: 50
  }];
  try {
    await generateMixedDispatchPlan('officer', { mode: 'mixed' },
      { jobId: 'job-active-tasks', workerToken: 'worker-active-tasks' });
    const vehicle = solve.mock.lastCall[0].vehicles.find(v => v.id === crewId);
    expect(vehicle).toBeDefined();
    // Crew has max 10 tasks, 1 active task -> 9 remaining
    expect(vehicle.max_tasks).toBe(9);
    // Total budget 495 min - 116 busy min = 379 min remaining
    expect(vehicle.remaining_budget_min).toBe(379);
    expect(vehicle.effective_budget_min).toBe(364);
    // Shift start: 480 (08:00), break: 60, buffer: 15 -> end = 480 + 60 + 364 = 904
    expect(vehicle.shift_end_min).toBe(904);
    // Starting load increases by busy load: 1 + 0.5 = 1.5, 100 + 50 = 150
    expect(vehicle.starting_volume_m3).toBe(1.5);
    expect(vehicle.starting_weight_kg).toBe(150);
  } finally {
    activeTasksMock = [];
  }
});

