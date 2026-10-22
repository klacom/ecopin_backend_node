import { jest } from '@jest/globals';

const rpc = jest.fn();
const from = jest.fn();
const resources = jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabase: { rpc, from }, supabaseAdmin: { rpc, from }
}));
jest.unstable_mockModule('cloudinary', () => ({
  v2: { config: jest.fn(), api: { resources } }
}));
const { getBatchReportEvidence, clearEvidenceServerCache } = await import('../src/controllers/report.controller.js');
const ids = Array.from({ length: 101 }, (_, i) => `00000000-0000-0000-0000-${String(i + 1).padStart(12, '0')}`);
const viewer = { id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', role: 'citizen' };
function response() {
  return { status: jest.fn().mockReturnThis(), json: jest.fn().mockReturnThis() };
}
function publicQuery(data, error = null) {
  const query = { select: jest.fn().mockReturnThis(), in: jest.fn().mockResolvedValue({ data, error }) };
  from.mockReturnValue(query);
  return query;
}
beforeEach(() => {
  jest.clearAllMocks();
  rpc.mockReset();
  from.mockReset();
  resources.mockReset().mockResolvedValue({ resources: [] });
  clearEvidenceServerCache();
});

test('100 reports use one permission RPC rather than 100 individual RPCs', async () => {
  rpc.mockResolvedValue({ data: ids.slice(0, 100).map(id => ({ id })), error: null });
  const res = response();
  const next = jest.fn();
  await getBatchReportEvidence({ body: { reportIds: ids.slice(0, 100) }, user: viewer }, res, next);
  expect(next).not.toHaveBeenCalled();
  expect(rpc).toHaveBeenCalledTimes(1);
  expect(rpc).toHaveBeenCalledWith('read_authorized_report_evidence_ids', {
    actor: viewer.id, report_ids: ids.slice(0, 100)
  });
  expect(Object.keys(res.json.mock.calls[0][0])).toHaveLength(100);
});

test('only approved IDs fetch evidence; denied IDs return empty arrays', async () => {
  rpc.mockResolvedValue({ data: [{ id: ids[0] }], error: null });
  const res = response();
  await getBatchReportEvidence({ body: { reportIds: ids.slice(0, 2) }, user: viewer }, res, jest.fn());
  expect(resources).toHaveBeenCalledTimes(2);
  expect(resources.mock.calls.every(([options]) => options.prefix === `report_evidence/${ids[0]}`)).toBe(true);
  expect(res.json).toHaveBeenCalledWith({ [ids[0]]: [], [ids[1]]: [] });
});

test('cached private evidence is reauthorized for every viewer', async () => {
  rpc.mockResolvedValueOnce({ data: [{ id: ids[0] }], error: null });
  resources.mockImplementation(async ({ resource_type }) => ({ resources: resource_type === 'image' ? [{
    public_id: `report_evidence/${ids[0]}/private`, secure_url: 'https://cdn/private.jpg', resource_type: 'image'
  }] : [] }));
  const ownerRes = response();
  await getBatchReportEvidence({ body: { reportIds: [ids[0]] }, user: viewer }, ownerRes, jest.fn());
  expect(ownerRes.json.mock.calls[0][0][ids[0]]).toHaveLength(1);
  resources.mockClear();
  rpc.mockResolvedValueOnce({ data: [], error: null });
  const strangerRes = response();
  await getBatchReportEvidence({ body: { reportIds: [ids[0]] }, user: { ...viewer, id: ids[100] } }, strangerRes, jest.fn());
  expect(strangerRes.json).toHaveBeenCalledWith({ [ids[0]]: [] });
  expect(rpc).toHaveBeenCalledTimes(2);
  expect(resources).not.toHaveBeenCalled();
});

test('permission failures propagate without fetching or returning evidence', async () => {
  const error = new Error('Database unavailable');
  rpc.mockResolvedValue({ data: null, error });
  const res = response();
  const next = jest.fn();
  await getBatchReportEvidence({ body: { reportIds: [ids[0]] }, user: viewer }, res, next);
  expect(next).toHaveBeenCalledWith(error);
  expect(res.json).not.toHaveBeenCalled();
  expect(resources).not.toHaveBeenCalled();
});

test('batch IDs remain deduplicated and capped at 100', async () => {
  rpc.mockResolvedValue({ data: [], error: null });
  await getBatchReportEvidence({ body: { reportIds: [ids[0], ...ids] }, user: viewer }, response(), jest.fn());
  expect(rpc).toHaveBeenCalledTimes(1);
  expect(rpc.mock.calls[0][1].report_ids).toEqual(ids.slice(0, 100));
});

test('invalid report IDs do not poison a valid batch', async () => {
  rpc.mockResolvedValue({ data: [], error: null });
  const res = response();
  await getBatchReportEvidence({ body: { reportIds: ['invalid', ids[0], null] }, user: viewer }, res, jest.fn());
  expect(rpc).toHaveBeenCalledWith('read_authorized_report_evidence_ids', { actor: viewer.id, report_ids: [ids[0]] });
  expect(resources).not.toHaveBeenCalled();
});

test('uppercase UUID input preserves evidence access and response keys', async () => {
  const id = 'abcdefab-abcd-abcd-abcd-abcdefabcdef';
  rpc.mockResolvedValue({ data: [{ id }], error: null });
  const res = response();
  await getBatchReportEvidence({ body: { reportIds: [id.toUpperCase()] }, user: viewer }, res, jest.fn());
  expect(resources).toHaveBeenCalledTimes(2);
  expect(res.json).toHaveBeenCalledWith({ [id.toUpperCase()]: [] });
});

test('empty or entirely invalid batches make no database calls', async () => {
  for (const reportIds of [[], ['invalid']]) {
    await getBatchReportEvidence({ body: { reportIds }, user: viewer }, response(), jest.fn());
  }
  expect(rpc).not.toHaveBeenCalled();
  expect(from).not.toHaveBeenCalled();
});

test('anonymous viewers retain the single public query and exact-location restriction', async () => {
  const query = publicQuery([{ id: ids[0], location_precision: 'exact' }, { id: ids[1], location_precision: 'approximate' }]);
  await getBatchReportEvidence({ body: { reportIds: ids.slice(0, 2) } }, response(), jest.fn());
  expect(rpc).not.toHaveBeenCalled();
  expect(from).toHaveBeenCalledTimes(1);
  expect(from).toHaveBeenCalledWith('public_reports');
  expect(query.in).toHaveBeenCalledWith('id', ids.slice(0, 2));
  expect(resources).toHaveBeenCalledTimes(2);
  expect(resources.mock.calls.every(([options]) => options.prefix === `report_evidence/${ids[0]}`)).toBe(true);
});


test('strict offline preparation propagates evidence provider failures instead of caching empty success', async () => {
  rpc.mockResolvedValue({data:[{id:ids[0]}],error:null});
  const error = new Error('Evidence provider unavailable');
  resources.mockRejectedValue(error);
  const res = response(); const next = jest.fn();
  await getBatchReportEvidence({body:{reportIds:[ids[0]],strict:true},user:viewer},res,next);
  expect(next).toHaveBeenCalledWith(error);
  expect(res.json).not.toHaveBeenCalled();
});
