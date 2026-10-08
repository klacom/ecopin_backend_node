import { jest } from '@jest/globals';

const rpc = jest.fn();
const logBreach = jest.fn();
const threshold = jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: { rpc } }));
jest.unstable_mockModule('../src/modules/sweeper/services/audit-log.service.js', () => ({ logSlaBreachDetection: logBreach }));
jest.unstable_mockModule('../src/modules/sweeper/services/configuration.service.js', () => ({ getSlaThreshold: threshold }));
const { slaDetectionService } = await import('../src/modules/sweeper/services/sla-detection.service.js');

afterEach(() => { jest.clearAllMocks(); delete process.env.REPORT_LIFECYCLE_ENABLED; });

test('legacy detection counts database changes even when audit fails', async () => {
  rpc.mockResolvedValue({ data: [{ report_id: 'r1', breach_duration: 50, flagged_at: '2026-10-08T00:00:00Z' }], error: null });
  logBreach.mockRejectedValue(new Error('audit unavailable'));
  const result = await slaDetectionService.detectAndFlagOutliers();
  expect(result.flaggedCount).toBe(1);
  expect(result.auditFailureCount).toBe(1);
});

test('threshold uses the canonical JSON configuration reader', async () => {
  threshold.mockResolvedValue(72);
  expect(await slaDetectionService.getSlaThreshold()).toBe(72);
});

test('lifecycle mode returns only new breaches and does not double-write audit', async () => {
  process.env.REPORT_LIFECYCLE_ENABLED = 'true';
  rpc.mockResolvedValue({ data: { skipped: false, changedCount: 2, newlyBreached: [{ id: 'r2', breachDuration: 1, timestamp: '2026-10-08T00:00:00Z' }] }, error: null });
  const result = await slaDetectionService.detectAndFlagOutliers();
  expect(rpc).toHaveBeenCalledWith('advance_report_lifecycle');
  expect(result.flaggedCount).toBe(1);
  expect(result.changedCount).toBe(2);
  expect(logBreach).not.toHaveBeenCalled();
});

test('RPC errors propagate instead of reporting successful zero changes', async () => {
  rpc.mockResolvedValue({ data: null, error: { message: 'permission denied' } });
  await expect(slaDetectionService.detectAndFlagOutliers()).rejects.toThrow('permission denied');
});
