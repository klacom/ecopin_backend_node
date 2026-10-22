import { jest } from '@jest/globals';

const rpc = jest.fn();
const from = jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabase: { from }, supabaseAdmin: { from, rpc }
}));
jest.unstable_mockModule('../src/controllers/auth.controller.js', () => ({ logAuditAction: jest.fn() }));
jest.unstable_mockModule('../src/services/officer-notification.service.js', () => ({ notifyOfficers: jest.fn() }));
const { getSystemStats } = await import('../src/controllers/admin.controller.js');
const { batchFcSync } = await import('../src/controllers/fc_sync.controller.js');
const response = () => ({ status: jest.fn().mockReturnThis(), json: jest.fn() });

beforeEach(() => jest.clearAllMocks());

test('statistics retain separate audit and system log tables after merging', async () => {
  from.mockImplementation(table => ({
    select: jest.fn(() => table === 'reports'
      ? { count: 0, range: async () => ({ data: [] }) }
      : { data: [], count: table === 'audit_logs' ? 37 : null })
  }));
  const res = response();
  await getSystemStats({}, res, error => { throw error; });
  expect(from.mock.calls.filter(([table]) => table === 'audit_logs')).toHaveLength(1);
  expect(from.mock.calls.filter(([table]) => table === 'system_logs')).toHaveLength(1);
  expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ auditLogs: { total: 37 } }));
});

test('offline operations retain atomic RPC authority bound to the authenticated actor', async () => {
  rpc.mockResolvedValue({ data: { status: 'applied' }, error: null });
  const operation = { operation_id: 'op-1', operation_type: 'fc.task.mark_complete',
    entity_id: 'task-1', entity_type: 'task', base_version: 3, payload: { user_id: 'other-user' } };
  const res = response();
  await batchFcSync({ user: { id: 'signed-in-crew' }, body: { operations: [operation] } }, res,
    error => { throw error; });
  expect(rpc).toHaveBeenCalledWith('apply_fc_operation', expect.objectContaining({
    actor: 'signed-in-crew', operation_id: 'op-1', base_version: 3
  }));
  expect(from).not.toHaveBeenCalled();
  expect(res.json).toHaveBeenCalledWith({ results: [{ status: 'applied' }] });
});

test('a mismatched report receipt is rejected before any database operation', async () => {
  const res = response();
  await batchFcSync({ user: { id: 'crew' }, body: { operations: [{
    operation_id: 'op-2', operation_type: 'fc.report.reconcile', entity_type: 'report',
    entity_id: 'report-one', payload: { report_id: 'report-two' }
  }] } }, res, error => { throw error; });
  expect(rpc).not.toHaveBeenCalled();
  expect(res.json).toHaveBeenCalledWith({ results: [expect.objectContaining({ status: 'rejected' })] });
});
