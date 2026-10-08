import { resolvePlanSettings, selectPlanItems, reportPriority } from '../src/modules/optimization/services/planningPolicy.js';

const crew = { id: 'crew', supports_standard: true, supports_sweeper: false, availability_status: 'available', shift_start: '08:00', shift_end: '10:00', max_tasks_per_shift: 2, member_profile_ids: ['member'], speed_factor: 1, service_time_factor: 1 };
const cluster = { item_type: 'cluster', cluster_id: 'cluster', group_key: 'cluster:cluster', report_ids: ['r1'], service_minutes: 30, priority_score: 80 };
const report = { item_type: 'report', report_id: 'r2', group_key: 'report:r2', report_ids: ['r2'], service_minutes: 30, priority_score: 90 };

test('Mixed remains unavailable until Slice B', () => {
  expect(() => resolvePlanSettings({ mode: 'mixed' })).toThrow('standard or sweeper');
});
test.each([{ break_duration_min: -1 }, { overtime_tolerance_min: Infinity }, { max_tasks_per_shift: 0 }, { capacity_utilization: 2 }])('reject invalid planning settings %o', value => {
  expect(() => resolvePlanSettings(value)).toThrow();
});
test('standard fleet cannot receive sweeper reports', () => {
  const result = selectPlanItems([report], [crew], [], resolvePlanSettings({ mode: 'sweeper' }));
  expect(result.items[0]).toMatchObject({ is_selected: false, reason: 'no_capable_crew' });
});
test('per-crew time budget preserves all unassigned candidates with a reason', () => {
  const result = selectPlanItems([cluster, { ...cluster, cluster_id: 'c2', group_key: 'cluster:c2', report_ids: ['r3'] }], [crew], [], resolvePlanSettings({}));
  expect(result.items[0].is_selected).toBe(true);
  expect(result.items[1]).toMatchObject({ is_selected: false, reason: 'insufficient_capacity' });
});
test('existing assignments consume capacity and task count', () => {
  const busy = [{ assigned_field_crew_id: 'crew', status: 'pending', estimated_duration_min: 60 }];
  const result = selectPlanItems([cluster], [crew], busy, resolvePlanSettings({}));
  expect(result.items[0].is_selected).toBe(false);
});
test('memberless crews are not dispatchable', () => {
  const result = selectPlanItems([cluster], [{ ...crew, member_profile_ids: [] }], [], resolvePlanSettings({}));
  expect(result.items[0].reason).toBe('no_capable_crew');
});
test('overnight shifts and service/speed factors are included', () => {
  const result = selectPlanItems([report], [{ ...crew, supports_sweeper: true, shift_start: '22:00', shift_end: '06:00', service_time_factor: 2, speed_factor: 0.5 }], [], resolvePlanSettings({ mode: 'sweeper' }));
  expect(result.items[0]).toMatchObject({ is_selected: true, estimated_duration_minutes: 110 });
});
test('report priority normalizes the actual 1–3 urgency scale', () => {
  const now = Date.parse('2026-10-08T00:00:00Z');
  expect(reportPriority({ severity_score: 0, urgency_score: 3, sla_started_at: '2026-10-08T00:00:00Z' }, undefined, now))
    .toBeGreaterThan(reportPriority({ severity_score: 0, urgency_score: 1, sla_started_at: '2026-10-08T00:00:00Z' }, undefined, now));
});


test('breached Sweeper reports precede higher-scored maturing reports', () => {
  const result = selectPlanItems([
    { ...report, lifecycle_state: 'maturing', priority_score: 100 },
    { ...report, group_key: 'report:breached', lifecycle_state: 'sla_breached', priority_score: 1 }
  ], [{ ...crew, supports_sweeper: true }], [], resolvePlanSettings({ mode: 'sweeper' }));
  expect(result.items[0]).toMatchObject({ group_key: 'report:breached', is_selected: true });
  expect(result.items[1]).toMatchObject({ is_selected: false, reason: 'insufficient_capacity' });
});
