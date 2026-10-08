import { jest } from '@jest/globals';
import { processNextPlanningJob } from '../src/modules/optimization/services/planJobs.service.js';

function clientFor(job) {
  const calls = [];
  return { calls, client: {
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { data: name === 'claim_plan_generation' ? job : { status: args.failure_code ? 'failed' : 'completed' }, error: null };
    },
    from: () => ({ update: () => ({ eq: () => ({ eq: () => ({ select: () => ({
      single: async () => ({ data: { id: 'plan-1' }, error: null })
    }) }) }) }) })
  } };
}

test('Mixed job has one generation and one terminal completion; no HTTP request owns the solve', async () => {
  const { client, calls } = clientFor({ id: 'job-1', requested_by: 'officer',
    mode: 'mixed', settings_snapshot: { mode: 'mixed' } });
  const generateMixed = jest.fn(async () => ({ plan: { id: 'plan-1' }, diagnostics: { elapsed_seconds: 2 } }));
  expect(await processNextPlanningJob({ client, generateMixed })).toBe(true);
  expect(generateMixed).toHaveBeenCalledTimes(1);
  expect(calls.map(call => call.name)).toEqual(['claim_plan_generation', 'finish_plan_generation']);
  expect(calls[1].args.result_plan_id).toBe('plan-1');
  expect(calls[1].args.worker_id).toBe(calls[0].args.worker_id);
});

test('a failed job terminates without a solver retry or partial plan result', async () => {
  const { client, calls } = clientFor({ id: 'job-2', requested_by: 'officer',
    mode: 'mixed', settings_snapshot: { mode: 'mixed' } });
  const generateMixed = jest.fn(async () => { throw new Error('solver_timeout'); });
  expect(await processNextPlanningJob({ client, generateMixed })).toBe(true);
  expect(generateMixed).toHaveBeenCalledTimes(1);
  expect(calls[1].args.result_plan_id).toBeNull();
  expect(calls[1].args.failure_code).toBe('solver_timeout');
});
