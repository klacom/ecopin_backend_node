import { jest } from '@jest/globals';
import { selectPlanItems, resolvePlanSettings } from '../src/modules/optimization/services/planningPolicy.js';

describe('Residual Capacity Planning & Viable Task Filtering (WT-88)', () => {
  const crewId = '00000000-0000-0000-0000-000000000030';
  const clusterSmallId = '00000000-0000-0000-0000-000000000210';
  const clusterLargeId = '00000000-0000-0000-0000-000000000220';

  const baseCrew = {
    id: crewId,
    name: 'North Sector Alpha',
    availability_status: 'available',
    supports_standard: true,
    supports_sweeper: true,
    member_profile_ids: ['member-1'],
    shift_start: '08:00',
    shift_end: '17:00',
    speed_factor: 1,
    service_time_factor: 1,
    max_tasks_per_shift: 10,
    max_volume_m3: 3.0,
    max_weight_kg: 500,
    starting_volume_m3: 0,
    starting_weight_kg: 0,
    certifications: [],
    hazmat_certified: false
  };

  test('selectPlanItems assigns smaller viable task and flags oversized task as exceeds_residual_capacity when crew has active tasks', () => {
    // Crew shift is 08:00 - 17:00 (540 min). Minus 60 break + 15 overtime = 495 min total budget.
    // Active task consumes 455 min, leaving 40 min remaining.
    const activeTasks = [{
      id: 'active-1',
      assigned_field_crew_id: crewId,
      status: 'in_progress',
      estimated_duration_min: 455,
      estimated_volume_m3: 1.0,
      estimated_weight_kg: 100
    }];

    const largeCandidate = {
      item_type: 'cluster',
      cluster_id: clusterLargeId,
      group_key: `cluster:${clusterLargeId}`,
      report_ids: ['rep-large'],
      service_minutes: 120, // 120 + 25 travel = 145 min (exceeds 40 min residual)
      priority_score: 95,
      estimated_volume_m3: 0.5,
      estimated_weight_kg: 50
    };

    const smallCandidate = {
      item_type: 'cluster',
      cluster_id: clusterSmallId,
      group_key: `cluster:${clusterSmallId}`,
      report_ids: ['rep-small'],
      service_minutes: 10, // 10 + 25 travel = 35 min (fits in 40 min residual)
      priority_score: 60,
      estimated_volume_m3: 0.2,
      estimated_weight_kg: 20
    };

    const settings = resolvePlanSettings({ mode: 'standard' });
    const result = selectPlanItems([largeCandidate, smallCandidate], [baseCrew], activeTasks, settings);

    // Large candidate cannot fit residual capacity
    const largeResult = result.items.find(i => i.group_key === `cluster:${clusterLargeId}`);
    expect(largeResult).toBeDefined();
    expect(largeResult.is_selected).toBe(false);
    expect(largeResult.reason).toBe('exceeds_residual_capacity');
    expect(largeResult.operational_label).toContain('Exceeds remaining crew capacity');

    // Small candidate fits within remaining 40 min and is selected
    const smallResult = result.items.find(i => i.group_key === `cluster:${clusterSmallId}`);
    expect(smallResult).toBeDefined();
    expect(smallResult.is_selected).toBe(true);
    expect(smallResult.reason).toBe('selected');
    expect(smallResult.planned_crew_id).toBe(crewId);

    // Summary alert message is included
    expect(result.residualCapacitySummary).toBeDefined();
    expect(result.residualCapacitySummary.has_active_tasks).toBe(true);
    expect(result.residualCapacitySummary.viable_count).toBe(1);
    expect(result.residualCapacitySummary.oversized_deferred_count).toBe(1);
    expect(result.residualCapacitySummary.alert_message).toContain('Filtered 1 viable tasks fitting remaining crew capacity');
  });

  test('selectPlanItems respects residual volume and weight constraints from active tasks', () => {
    // Crew has max 3.0 m3, starting 0. Active task has 2.6 m3 -> residual volume is 0.4 m3
    const activeTasks = [{
      id: 'active-vol',
      assigned_field_crew_id: crewId,
      status: 'pending',
      estimated_duration_min: 60,
      estimated_volume_m3: 2.6,
      estimated_weight_kg: 100
    }];

    const heavyVolumeCandidate = {
      item_type: 'cluster',
      cluster_id: clusterLargeId,
      group_key: `cluster:${clusterLargeId}`,
      report_ids: ['rep-vol'],
      service_minutes: 20,
      priority_score: 90,
      estimated_volume_m3: 1.0, // 1.0 m3 exceeds 0.4 m3 residual
      estimated_weight_kg: 30
    };

    const lightVolumeCandidate = {
      item_type: 'cluster',
      cluster_id: clusterSmallId,
      group_key: `cluster:${clusterSmallId}`,
      report_ids: ['rep-light'],
      service_minutes: 20,
      priority_score: 50,
      estimated_volume_m3: 0.2, // 0.2 m3 fits in 0.4 m3 residual
      estimated_weight_kg: 10
    };

    const settings = resolvePlanSettings({ mode: 'standard' });
    const result = selectPlanItems([heavyVolumeCandidate, lightVolumeCandidate], [baseCrew], activeTasks, settings);

    const heavyResult = result.items.find(i => i.group_key === `cluster:${clusterLargeId}`);
    expect(heavyResult.is_selected).toBe(false);
    expect(heavyResult.reason).toBe('exceeds_residual_capacity');

    const lightResult = result.items.find(i => i.group_key === `cluster:${clusterSmallId}`);
    expect(lightResult.is_selected).toBe(true);
    expect(lightResult.reason).toBe('selected');
  });

  test('generateMixedDispatchPlan filters candidates by residual capacity and provides officer alert diagnostics', async () => {
    let savedArgs = null;
    const activeTasksMock = [{
      assigned_field_crew_id: crewId,
      status: 'assigned',
      estimated_duration_min: 440, // 495 - 440 = 55 min remaining; effective budget 55 - 15 = 40 min
      estimated_volume_m3: 2.5,     // 3.0 - 2.5 = 0.5 m3 remaining
      estimated_weight_kg: 400      // 500 - 400 = 100 kg remaining
    }];

    const snapshotMock = {
      anchors: [
        {
          id: clusterLargeId,
          lat: 14.0,
          lng: 121.0,
          priority_score: 90,
          estimated_effort_minutes: 90, // 90 min effort exceeds 40 min effective residual
          created_at: '2026-10-08T00:00:00Z',
          estimated_volume_m3: 0.8,     // 0.8 exceeds 0.5 m3 residual
          estimated_weight_kg: 50,
          report_ids: ['00000000-0000-0000-0000-000000000301']
        },
        {
          id: clusterSmallId,
          lat: 14.01,
          lng: 121.01,
          priority_score: 60,
          estimated_effort_minutes: 15, // 15 min effort fits in 40 min effective residual
          created_at: '2026-10-08T00:00:00Z',
          estimated_volume_m3: 0.1,     // 0.1 fits in 0.5 m3 residual
          estimated_weight_kg: 10,
          report_ids: ['00000000-0000-0000-0000-000000000302']
        }
      ],
      satellites: []
    };

    const settingsRows = [
      { key: 'swmo_depot', value: { latitude: 14, longitude: 121 } },
      { key: 'mixed_spatial_buffer_meters', value: 1500 },
      { key: 'mixed_max_reports_per_anchor', value: 5 },
      { key: 'mixed_max_detour_minutes', value: 30 },
      { key: 'solver_time_limit_seconds', value: 2 },
      { key: 'solver_max_candidate_nodes', value: 200 },
      { key: 'mixed_bundle_reserve_pct', value: 20 },
      { key: 'mcda_weights', value: { severity: 0.4, urgency: 0.25, report_count: 0.15, waiting_time: 0.15, weather: 0.05 } }
    ];

    const db = {
      from: table => ({
        select: () => ({
          then: resolve => resolve({ data: table === 'optimization_settings' ? settingsRows : [], error: null }),
          eq: () => Promise.resolve({ data: table === 'field_crews' ? [baseCrew] : [], error: null }),
          not: () => Promise.resolve({ data: table === 'cleanup_tasks' ? activeTasksMock : [], error: null })
        })
      }),
      rpc: async (name, args) => {
        if (name === 'mixed_planning_snapshot') return { data: snapshotMock, error: null };
        if (name === 'save_mixed_dispatch_draft') {
          savedArgs = args;
          return { data: { id: 'plan-residual-test' }, error: null };
        }
        throw new Error(`Unexpected RPC ${name}`);
      }
    };

    const solve = jest.fn(async payload => ({
      contract_version: 'v5',
      status: 'success',
      routes: [{
        vehicle_id: crewId,
        stops: payload.tasks.map(t => ({
          task_id: t.id,
          volume_after_m3: 2.6,
          weight_after_kg: 410
        }))
      }],
      unassigned: [],
      solver_diagnostics: { elapsed_seconds: 1 }
    }));

    const matrix = jest.fn(async points => points.map((_, i) => points.map((_, j) => (i === j ? 0 : 120))));

    jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: db }));
    jest.unstable_mockModule('../src/modules/optimization/services/workQueue.service.js', () => ({ prioritizeBacklog: jest.fn(async () => []) }));
    jest.unstable_mockModule('../src/modules/optimization/providers/tomtom.provider.js', () => ({ getTomTomDistanceMatrix: matrix }));
    jest.unstable_mockModule('../src/modules/optimization/services/ortools.service.js', () => ({ solveVRPWithOrTools: solve }));

    const { generateMixedDispatchPlan } = await import('../src/modules/optimization/services/mixedPlanner.service.js');

    const result = await generateMixedDispatchPlan('officer-1', { mode: 'mixed' }, { jobId: 'job-res-1', workerToken: 'worker-res-1' });
    expect(result.plan.id).toBe('plan-residual-test');

    // Verify solve payload ONLY received the small viable task, not the oversized task!
    expect(solve).toHaveBeenCalledTimes(1);
    const solverPayload = solve.mock.calls[0][0];
    const taskIdsPassedToSolver = solverPayload.tasks.map(t => t.id);
    expect(taskIdsPassedToSolver).toContain(`cluster:${clusterSmallId}`);
    expect(taskIdsPassedToSolver).not.toContain(`cluster:${clusterLargeId}`);

    // Verify saved items contain the oversized task with reason 'exceeds_residual_capacity'
    const largeItem = savedArgs.items.find(i => i.group_key === `cluster:${clusterLargeId}`);
    expect(largeItem).toBeDefined();
    expect(largeItem.is_selected).toBe(false);
    expect(largeItem.reason).toBe('exceeds_residual_capacity');

    // Verify small viable task is scheduled
    const smallItem = savedArgs.items.find(i => i.group_key === `cluster:${clusterSmallId}`);
    expect(smallItem).toBeDefined();
    expect(smallItem.is_selected).toBe(true);

    // Verify capacity_filtering diagnostics are populated for the officer
    const filtering = savedArgs.diagnostics.capacity_filtering;
    expect(filtering).toBeDefined();
    expect(filtering.has_active_tasks).toBe(true);
    expect(filtering.viable_candidates_count).toBe(1);
    expect(filtering.filtered_oversized_count).toBe(1);
    expect(filtering.alert_message).toContain('Filtered 1 viable tasks fitting remaining crew capacity (1 oversized tasks deferred to prevent plan cancellation)');
    expect(filtering.crew_residual_capacities[0]).toMatchObject({
      crew_id: crewId,
      remaining_tasks: 9,
      remaining_minutes: 40
    });
  });
});
