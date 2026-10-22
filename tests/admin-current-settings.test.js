import { jest } from '@jest/globals';
let current;
const query = { order: jest.fn().mockReturnThis(), limit: jest.fn().mockReturnThis(),
  select: jest.fn().mockReturnThis(), maybeSingle: jest.fn(async () => ({ data: current, error: null })),
  upsert: jest.fn(settings => { current = { ...current, ...settings }; return query; }),
  single: jest.fn(async () => ({ data: current, error: null })) };
const from = jest.fn(() => query);
const saveCms = jest.fn(async () => ({}));
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabase: { from }, supabaseAdmin: { from } }));
jest.unstable_mockModule('../src/controllers/auth.controller.js', () => ({ logAuditAction: jest.fn() }));
jest.unstable_mockModule('../src/services/cms.service.js', () => ({ getCmsSettingsService: async () => ({}), saveCmsSettingsService: saveCms, uploadCmsMediaService: jest.fn() }));
const { getSystemSettings, updateSystemSettings } = await import('../src/controllers/admin.controller.js');
const response = () => ({ code: 200, status(code) { this.code = code; return this; }, json(body) { this.body = body; return this; } });
beforeEach(() => {
  jest.clearAllMocks();
  current = { id: 'latest-settings', report_video_max_seconds: 8, daily_report_quota: 10 };
  query.maybeSingle.mockResolvedValue({ data: current, error: null });
});
test('admin loads the latest settings using a deterministic one-row query', async () => {
  const res = response(); await getSystemSettings({}, res, error => { throw error; });
  expect(res.body.id).toBe('latest-settings');
  expect(res.body.report_video_max_seconds).toBe(8);
  expect(query.order).toHaveBeenCalledWith('updated_at', { ascending: false, nullsFirst: false });
  expect(query.limit).toHaveBeenCalledWith(1);
});
test('an old client omitting row ID updates the current row rather than inserting another', async () => {
  const res = response();
  await updateSystemSettings({ body: { report_video_max_seconds: 7 }, user: { id: 'admin' }, ip: '127.0.0.1', get: () => 'test' }, res, error => { throw error; });
  expect(query.upsert).toHaveBeenCalledWith({ id: 'latest-settings', report_video_max_seconds: 7 });
  expect(res.body.settings.report_video_max_seconds).toBe(7);
});
test('stale row identifiers do not overwrite another saved configuration or save CMS drafts', async () => {
  const res = response();
  await updateSystemSettings({ body: { id: 'old-settings', report_video_max_seconds: 7, cms: {} } }, res, error => { throw error; });
  expect(res.code).toBe(409); expect(query.upsert).not.toHaveBeenCalled(); expect(saveCms).not.toHaveBeenCalled();
});
test('a failed current-settings read cannot insert a replacement/default row', async () => {
  query.maybeSingle.mockResolvedValueOnce({ data: null, error: { message: 'offline' } });
  const res = response();
  await updateSystemSettings({ body: { report_video_max_seconds: 7, cms: {} } }, res, error => { throw error; });
  expect(res.code).toBe(503); expect(query.upsert).not.toHaveBeenCalled(); expect(saveCms).not.toHaveBeenCalled();
});
