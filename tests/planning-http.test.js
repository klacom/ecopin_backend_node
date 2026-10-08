import { jest } from '@jest/globals';

const enqueuePlan = jest.fn(async () => ({ jobId: 'job-1', status: 'queued' }));
const readPlanJob = jest.fn(async () => ({ jobId: 'job-1', status: 'completed', planId: 'plan-1' }));
jest.unstable_mockModule('../src/modules/optimization/services/planJobs.service.js', () => ({ enqueuePlan, readPlanJob }));
const { generatePlan, getPlanJob } = await import('../src/modules/optimization/controllers/optimization.controller.js');

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
