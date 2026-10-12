import { jest } from '@jest/globals';

const rpc = jest.fn();
const db = {
  from(table) {
    if (table === 'dispatch_plans') return {
      select: () => ({ eq: () => ({ single: async () => ({
        data: { mode: 'mixed', route_proposal: {}, settings_snapshot: {} }, error: null
      }) }) })
    };
    if (table === 'dispatch_plan_items') return {
      select: () => ({ eq: () => ({ eq: () => ({ neq: async () => ({ count: 0, error: null }) }) }) })
    };
    throw new Error(`Unexpected table ${table}`);
  },
  rpc
};

jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: db }));
jest.unstable_mockModule('../src/modules/optimization/services/routeGenerator.service.js', () => ({
  generateRouteForCrew: jest.fn()
}));
jest.unstable_mockModule('../src/modules/optimization/services/crewAssigner.service.js', () => ({
  assignTasksToCrews: jest.fn()
}));
const { commitAndRoutePlan } = await import('../src/modules/optimization/services/dispatchCommit.service.js');

test('an empty draft stays uncommitted and cannot report published routes', async () => {
  const result = await commitAndRoutePlan('plan-id', 'officer-id');
  expect(result).toMatchObject({ routing_status: 'empty', tasks: [], run: null });
  expect(rpc).not.toHaveBeenCalled();
});
