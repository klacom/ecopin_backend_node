import { jest } from '@jest/globals';

const rpc = jest.fn();
const uploadFromBuffer = jest.fn();
const deleteFromCloudinary = jest.fn();
const upload = jest.fn();
const remove = jest.fn();
const bucket = jest.fn(() => ({ upload, remove }));
let report;
let task;
const from = jest.fn(table => ({
  select: () => ({
    eq: () => ({
      maybeSingle: async () => ({ data: table === 'reports' ? report : task, error: null })
    })
  })
}));
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: { rpc, from, storage: { from: bucket } } }));
jest.unstable_mockModule('../src/services/cloudinary.service.js', () => ({ uploadFromBuffer, deleteFromCloudinary }));
const { uploadFieldReportPhoto } = await import('../src/controllers/field-report-photo.controller.js');

function response() {
  return { code: 200, status(code) { this.code = code; return this; }, json(body) { this.body = body; return this; } };
}
async function run(user = 'assigned', photoType = 'before') {
  const res = response();
  let failure;
  await uploadFieldReportPhoto({
    params: { id: 'report' }, user: { id: user },
    body: { photo_type: photoType, base_version: '4' },
    file: { buffer: Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex'), mimetype: 'image/png' }
  }, res, error => { failure = error; });
  return { res, failure };
}
beforeEach(() => {
  report = { id: 'report', cleanup_task_id: 'task', fc_version: 4, status: 'unresolved' };
  task = { status: 'pending', route_status: 'ready', assigned_crew_ids: ['assigned'] };
  rpc.mockReset(); from.mockClear(); uploadFromBuffer.mockReset(); deleteFromCloudinary.mockReset();
  upload.mockReset(); remove.mockReset(); bucket.mockClear();
  upload.mockResolvedValue({ error: null }); remove.mockResolvedValue({ error: null });
});
test('foreign crew cannot upload a report photo', async () => {
  const { failure } = await run('foreign');
  expect(failure.statusCode).toBe(403);
  expect(upload).not.toHaveBeenCalled();
  expect(rpc).not.toHaveBeenCalled();
});
test('stale version fails before storage upload', async () => {
  report.fc_version = 5;
  const { failure } = await run();
  expect(failure.statusCode).toBe(409);
  expect(upload).not.toHaveBeenCalled();
});
test('a report changed during upload rejects the database write and removes the new private storage object', async () => {
  rpc.mockResolvedValue({ data: { status: 'conflict', error_message: 'Report version changed' }, error: null });
  const { failure } = await run();
  expect(failure.statusCode).toBe(409);
  expect(bucket).toHaveBeenCalledWith('Cleanup Originals');
  const stored = upload.mock.calls[0][0];
  expect(stored).toMatch(/^report\/before\/[0-9a-f-]{36}\.png$/);
  expect(remove).toHaveBeenCalledWith([stored]);
  expect(uploadFromBuffer).not.toHaveBeenCalled();
  expect(deleteFromCloudinary).not.toHaveBeenCalled();
});

test('private storage trouble is a retryable 503 and nothing is written to the report', async () => {
  upload.mockResolvedValue({ error: { message: 'storage down' } });
  const { failure } = await run();
  expect(failure.statusCode).toBe(503);
  expect(rpc).not.toHaveBeenCalled();
  expect(remove).not.toHaveBeenCalled();
});
test('assigned crew photo returns the authoritative new version', async () => {
  rpc.mockResolvedValue({ data: { status: 'success', server_record: { id: 'report', fc_version: 5 } }, error: null });
  const { res, failure } = await run();
  expect(failure).toBeUndefined();
  expect(res.body.report.fc_version).toBe(5);
  expect(rpc).toHaveBeenCalledWith('set_report_before_photo', expect.objectContaining({ actor: 'assigned', expected_version: 4, photo_key: expect.any(String) }));
  // The stored reference is private (storage://), never a public URL, and nothing is deleted on success.
  expect(rpc.mock.calls[0][1].photo_url ?? JSON.stringify(rpc.mock.calls[0][1])).toMatch(/storage:\/\/Cleanup%20Originals\/report\/before\//);
  expect(remove).not.toHaveBeenCalled();
});

test('assigned crew After photo uses set_report_after_photo collection RPC', async () => {
  rpc.mockResolvedValue({ data: { status: 'success', server_record: { id: 'report', fc_version: 5 } }, error: null });
  const { res, failure } = await run('assigned', 'after');
  expect(failure).toBeUndefined();
  expect(res.body.report.fc_version).toBe(5);
  expect(rpc).toHaveBeenCalledWith('set_report_after_photo', expect.objectContaining({ actor: 'assigned', expected_version: 4, photo_key: expect.any(String) }));
});

test('sixth Before photo is rejected before cloud storage allocation', async () => {
 report.before_photos=Array.from({length:5},(_,i)=>({id:`p${i}`,hash:`h${i}`,url:`https://cdn.example/${i}`}));
 const {res,failure}=await run();
 expect(failure).toBeUndefined();
 expect(res.code).toBe(400);
 expect(upload).not.toHaveBeenCalled();
 expect(rpc).not.toHaveBeenCalled();
});

test('sixth After photo is rejected before cloud storage allocation', async () => {
 report.after_photos=Array.from({length:5},(_,i)=>({id:`p${i}`,hash:`h${i}`,url:`https://cdn.example/${i}`}));
 const {res,failure}=await run('assigned', 'after');
 expect(failure).toBeUndefined();
 expect(res.code).toBe(400);
 expect(upload).not.toHaveBeenCalled();
 expect(rpc).not.toHaveBeenCalled();
});
