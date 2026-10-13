import { jest } from '@jest/globals';

const enqueuePlan = jest.fn(async () => ({ jobId: 'job-1', status: 'queued' }));
const readPlanJob = jest.fn(async () => ({ jobId: 'job-1', status: 'completed', planId: 'plan-1' }));
const processNextPlanningJob = jest.fn(async () => null);
jest.unstable_mockModule('../src/modules/optimization/services/planJobs.service.js', () => ({ enqueuePlan, readPlanJob, processNextPlanningJob }));
const { generatePlan, getPlanJob, getOptimizationOptions } = await import('../src/modules/optimization/controllers/optimization.controller.js');

function response() {
  return { status: jest.fn().mockReturnThis(), json: jest.fn().mockReturnThis() };
}

test('POST plan/generate returns 202 with a durable job id without awaiting routing', async () => {
  const req = { user: { id: 'officer' }, body: { settings: { mode: 'mixed' } },
    get: () => 'same-request' };
  const res = response();
  const next = jest.fn();
  await generatePlan(req, res, next);
  expect(next).not.toHaveBeenCalled();
  expect(enqueuePlan).toHaveBeenCalledWith('officer', { mode: 'mixed' }, 'same-request');
  expect(res.status).toHaveBeenCalledWith(202);
  expect(res.json).toHaveBeenCalledWith({ jobId: 'job-1', status: 'queued' });
});

test('GET job endpoint exposes completed draft id for polling', async () => {
  const res = response();
  await getPlanJob({ user: { id: 'officer' }, params: { jobId: 'job-1' } }, res, jest.fn());
  expect(readPlanJob).toHaveBeenCalledWith('job-1', 'officer');
  expect(res.json).toHaveBeenCalledWith({ jobId: 'job-1', status: 'completed', planId: 'plan-1' });
});

test('GET /api/optimization/options returns system metadata and taxonomy options', async () => {
  const res = response();
  const next = jest.fn();
  await getOptimizationOptions({ user: { id: 'officer' } }, res, next);
  expect(next).not.toHaveBeenCalled();
  expect(res.status).toHaveBeenCalledWith(200);
  const data = res.json.mock.calls[0][0];
  expect(data).toHaveProperty('travel_modes');
  expect(data.travel_modes.map(m => m.value)).toEqual(['WALKING', 'BICYCLE', 'MOTORCYCLE', 'DRIVING']);
  expect(data).toHaveProperty('task_types');
  expect(data).toHaveProperty('overtime_options');
  expect(data).toHaveProperty('break_durations');
  expect(data).toHaveProperty('workflow_targets');
});
