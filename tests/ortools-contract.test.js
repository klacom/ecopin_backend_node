import { jest } from '@jest/globals';
import { solveVRPWithOrTools } from '../src/modules/optimization/services/ortools.service.js';

const payload = { contract_version: 'v5', options: { solver_time_limit_seconds: 2 }, vehicles: [], tasks: [] };

test('adapter sends exactly one bounded v5 request and validates its response', async () => {
  const fetchImpl = jest.fn(async (_url, request) => ({ ok: true, json: async () => ({ contract_version: 'v5', routes: [], unassigned: [] }), request }));
  const result = await solveVRPWithOrTools(payload, { fetchImpl });
  expect(result.routes).toEqual([]);
  expect(fetchImpl).toHaveBeenCalledTimes(1);
  expect(JSON.parse(fetchImpl.mock.calls[0][1].body)).toEqual(payload);
  expect(fetchImpl.mock.calls[0][1].signal).toBeInstanceOf(AbortSignal);
});

test('adapter rejects stale contract and invalid solver response', async () => {
  await expect(solveVRPWithOrTools({ ...payload, contract_version: 'v4' })).rejects.toThrow('v5');
  await expect(solveVRPWithOrTools(payload, { fetchImpl: async () => ({ ok: true, json: async () => ({ routes: [] }) }) }))
    .rejects.toThrow('invalid v5');
});
