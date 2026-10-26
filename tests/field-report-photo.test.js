import { jest } from '@jest/globals';

const rpc = jest.fn();
const uploadFromBuffer = jest.fn();
const deleteFromCloudinary = jest.fn();
let report;
let task;
const from = jest.fn(table => ({
  select: () => ({
    eq: () => ({
      maybeSingle: async () => ({ data: table === 'reports' ? report : task, error: null })
    })
  })
}));
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: { rpc, from } }));
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
});
test('foreign crew cannot upload a report photo', async () => {
  const { failure } = await run('foreign');
  expect(failure.statusCode).toBe(403);
  expect(uploadFromBuffer).not.toHaveBeenCalled();
  expect(rpc).not.toHaveBeenCalled();
});
test('stale version fails before storage upload', async () => {
  report.fc_version = 5;
  const { failure } = await run();
  expect(failure.statusCode).toBe(409);
  expect(uploadFromBuffer).not.toHaveBeenCalled();
});
test('a report changed during upload rejects the database write and removes the new storage object', async () => {
  uploadFromBuffer.mockResolvedValue({ secure_url: 'https://cdn.example/new' });
  rpc.mockResolvedValue({ data: { status: 'conflict', error_message: 'Report version changed' }, error: null });
  const { failure } = await run();
  expect(failure.statusCode).toBe(409);
  expect(deleteFromCloudinary).toHaveBeenCalledWith('https://cdn.example/new');
});
test('assigned crew photo returns the authoritative new version', async () => {
  uploadFromBuffer.mockResolvedValue({ secure_url: 'https://cdn.example/new' });
  rpc.mockResolvedValue({ data: { status: 'success', server_record: { id: 'report', fc_version: 5 } }, error: null });
  const { res, failure } = await run();
  expect(failure).toBeUndefined();
  expect(res.body.report.fc_version).toBe(5);
  expect(rpc).toHaveBeenCalledWith('set_report_before_photo', expect.objectContaining({ actor: 'assigned', expected_version: 4, photo_key: expect.any(String) }));
});

test('assigned crew After photo uses set_report_after_photo collection RPC', async () => {
  uploadFromBuffer.mockResolvedValue({ secure_url: 'https://cdn.example/after' });
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
 expect(uploadFromBuffer).not.toHaveBeenCalled();
 expect(rpc).not.toHaveBeenCalled();
});

test('sixth After photo is rejected before cloud storage allocation', async () => {
 report.after_photos=Array.from({length:5},(_,i)=>({id:`p${i}`,hash:`h${i}`,url:`https://cdn.example/${i}`}));
 const {res,failure}=await run('assigned', 'after');
 expect(failure).toBeUndefined();
 expect(res.code).toBe(400);
 expect(uploadFromBuffer).not.toHaveBeenCalled();
 expect(rpc).not.toHaveBeenCalled();
});
