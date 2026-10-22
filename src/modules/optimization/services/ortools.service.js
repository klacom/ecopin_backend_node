/** One bounded v5 solve per planning batch. The caller owns job lifecycle. */
export async function solveVRPWithOrTools(payload, { signal, fetchImpl = globalThis.fetch } = {}) {
  if (payload?.contract_version !== 'v5') throw new Error('v5 solver payload required');
  const limit = payload.options?.solver_time_limit_seconds;
  if (!Number.isFinite(limit) || limit < 2 || limit > 60) throw new Error('Invalid solver time limit');
  const url = process.env.USE_AWS_VRP === 'true'
    ? process.env.AWS_VRP_SERVICE_URL
    : (process.env.LOCAL_VRP_SERVICE_URL || 'http://127.0.0.1:8003/solve_vrp');
  if (!url) throw new Error('VRP service URL is missing');
  const deadline = AbortSignal.timeout((limit + 3) * 1000);
  const response = await fetchImpl(url, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload), signal: signal ? AbortSignal.any([signal, deadline]) : deadline
  });
  if (!response.ok) throw new Error(`VRP service returned ${response.status}: ${(await response.text()).slice(0, 500)}`);
  const result = await response.json();
  if (result.contract_version !== 'v5' || !Array.isArray(result.routes) || !Array.isArray(result.unassigned)) {
    throw new Error('VRP service returned an invalid v5 response');
  }
  return result;
}
