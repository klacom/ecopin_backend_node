import { jest } from '@jest/globals';

const processMock = jest.fn();
jest.unstable_mockModule('../src/modules/optimization/services/planJobs.service.js', () => ({
  processNextPlanningJob: processMock
}));

const { tick, startPlanningWorker, stopPlanningWorker, getWorkerState } = await import('../src/jobs/planning-worker.js');

describe('Planning Worker Adaptive Backoff', () => {
  beforeEach(() => {
    stopPlanningWorker();
    processMock.mockReset();
  });

  afterEach(() => {
    stopPlanningWorker();
  });

  test('idle ticks back off progressively up to 15000ms', async () => {
    processMock.mockResolvedValue(false); // Idle, no jobs

    expect(getWorkerState().currentDelay).toBe(2000);

    // Tick 1 (idle) -> delay backs off to 5000
    await tick();
    expect(getWorkerState().currentDelay).toBe(5000);

    // Tick 2 (idle) -> delay backs off to 8000
    await tick();
    expect(getWorkerState().currentDelay).toBe(8000);

    // Tick 3 (idle) -> delay backs off to 11000
    await tick();
    expect(getWorkerState().currentDelay).toBe(11000);

    // Tick 4 (idle) -> delay backs off to 14000
    await tick();
    expect(getWorkerState().currentDelay).toBe(14000);

    // Tick 5 (idle) -> capped at 15000
    await tick();
    expect(getWorkerState().currentDelay).toBe(15000);

    // Tick 6 (idle) -> remains capped at 15000
    await tick();
    expect(getWorkerState().currentDelay).toBe(15000);
  });

  test('claimed job immediately resets delay back to MIN_DELAY (2000ms)', async () => {
    processMock.mockResolvedValue(false);
    await tick();
    await tick();
    expect(getWorkerState().currentDelay).toBe(8000);

    // Next tick finds a job!
    processMock.mockResolvedValue(true);
    await tick();
    expect(getWorkerState().currentDelay).toBe(2000);
  });

  test('start and stop planning worker accurately update scheduler state', () => {
    expect(getWorkerState().isScheduled).toBe(false);
    startPlanningWorker();
    expect(getWorkerState().isScheduled).toBe(true);
    stopPlanningWorker();
    expect(getWorkerState().isScheduled).toBe(false);
  });
});
