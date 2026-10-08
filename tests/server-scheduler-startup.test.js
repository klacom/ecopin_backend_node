import { jest } from '@jest/globals';

test('normal server entrypoint starts and stops the SLA scheduler', async () => {
  const server = { on: jest.fn(), close: jest.fn(callback => callback()) };
  const start = jest.fn();
  const stop = jest.fn();
  const listeners = new Map();
  jest.unstable_mockModule('../src/app.js', () => ({ default: { listen: jest.fn(() => server) } }));
  jest.unstable_mockModule('../src/config/index.js', () => ({ PORT: 3000, NODE_ENV: 'test', NEXT_PUBLIC_SUPABASE_URL: 'test' }));
  jest.unstable_mockModule('../src/modules/spatial_forecast/services/forecastScheduler.service.js', () => ({ startAllSchedules: jest.fn() }));
  jest.unstable_mockModule('../src/jobs/cron.js', () => ({ startSlaSchedule: start, stopSlaSchedule: stop }));
  const on = jest.spyOn(process, 'on').mockImplementation((event, handler) => { listeners.set(event, handler); return process; });
  const log = jest.spyOn(console, 'log').mockImplementation(() => {});
  try {
    await import('../src/index.js');
    expect(start).toHaveBeenCalledTimes(1);
    listeners.get('SIGTERM')();
    expect(stop).toHaveBeenCalledTimes(1);
    expect(server.close).toHaveBeenCalledTimes(1);
  } finally {
    on.mockRestore();
    log.mockRestore();
  }
});
