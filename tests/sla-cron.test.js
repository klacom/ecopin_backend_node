import { jest } from '@jest/globals';

jest.unstable_mockModule('../src/modules/sweeper/services/sla-detection.service.js', () => ({ slaDetectionService: { detectAndFlagOutliers: jest.fn() } }));
const { startSlaSchedule, stopSlaSchedule } = await import('../src/jobs/cron.js');

afterEach(() => stopSlaSchedule());

function dependencies() {
  return { scheduler: { schedule: jest.fn(() => ({ stop: jest.fn() })), validate: jest.fn(() => true) }, service: { detectAndFlagOutliers: jest.fn().mockResolvedValue({ flaggedCount: 1 }) }, logger: { info: jest.fn(), error: jest.fn() } };
}

test('scheduler is opt-in until the lifecycle migration is deployed', () => {
  const deps = dependencies();
  expect(startSlaSchedule({ ...deps, env: {} })).toBeNull();
  expect(deps.scheduler.schedule).not.toHaveBeenCalled();
});

test('startup registers exactly one hourly job with an explicit timezone', () => {
  const deps = dependencies();
  const opts = { ...deps, env: { REPORT_LIFECYCLE_ENABLED: 'true' } };
  const task = startSlaSchedule(opts);
  expect(startSlaSchedule(opts)).toBe(task);
  expect(deps.scheduler.schedule).toHaveBeenCalledTimes(1);
  expect(deps.scheduler.schedule).toHaveBeenCalledWith('0 * * * *', expect.any(Function), { timezone: 'Asia/Manila' });
});

test('tick failures are logged and a later tick can run', async () => {
  const deps = dependencies();
  deps.service.detectAndFlagOutliers.mockRejectedValueOnce(new Error('database offline'));
  startSlaSchedule({ ...deps, env: { REPORT_LIFECYCLE_ENABLED: 'true' } });
  const tick = deps.scheduler.schedule.mock.calls[0][1];
  await tick();
  await tick();
  expect(deps.logger.error).toHaveBeenCalled();
  expect(deps.service.detectAndFlagOutliers).toHaveBeenCalledTimes(2);
});

test('overlapping ticks do not start a second RPC', async () => {
  const deps = dependencies();
  let finish;
  deps.service.detectAndFlagOutliers.mockReturnValue(new Promise(resolve => { finish = resolve; }));
  startSlaSchedule({ ...deps, env: { REPORT_LIFECYCLE_ENABLED: 'true' } });
  const tick = deps.scheduler.schedule.mock.calls[0][1];
  const first = tick();
  await tick();
  expect(deps.service.detectAndFlagOutliers).toHaveBeenCalledTimes(1);
  finish({ flaggedCount: 0 });
  await first;
});

test('invalid cron configuration fails before registering', () => {
  const deps = dependencies();
  deps.scheduler.validate.mockReturnValue(false);
  expect(() => startSlaSchedule({ ...deps, env: { REPORT_LIFECYCLE_ENABLED: 'true', SLA_DETECTION_CRON: 'bad' } })).toThrow('Invalid SLA_DETECTION_CRON');
  expect(deps.scheduler.schedule).not.toHaveBeenCalled();
});
