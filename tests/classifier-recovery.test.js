import { jest } from '@jest/globals';

process.env.CLASSIFIER_SERVICE_URL = 'http://classifier.test';
process.env.USE_AWS_CLASSIFIER = 'false';
const from = jest.fn();
const uploadFromBuffer = jest.fn();
const notifyOfficers = jest.fn().mockResolvedValue();
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabase: { from }, supabaseAdmin: { from, rpc: jest.fn() }
}));
jest.unstable_mockModule('cloudinary', () => ({ v2: { config: jest.fn() } }));
jest.unstable_mockModule('../src/services/cloudinary.service.js', () => ({
  uploadFromBuffer, uploadVideoFromBuffer: jest.fn(), deleteFromCloudinary: jest.fn()
}));
jest.unstable_mockModule('../src/services/geocoding.service.js', () => ({ resolveAddressDetails: jest.fn() }));
jest.unstable_mockModule('../src/services/reportQuota.service.js', () => ({
  checkUserReportQuota: jest.fn(), recordReportSubmission: jest.fn()
}));
jest.unstable_mockModule('../src/services/officer-notification.service.js', () => ({ notifyOfficers }));
jest.unstable_mockModule('../src/modules/clustering/index.js', () => ({ clusterReports: jest.fn().mockResolvedValue() }));
const { createReport, syncReportMedia } = await import('../src/controllers/report.controller.js');
const { classifyImage } = await import('../src/services/classifierClient.service.js');
const originalFetch = global.fetch;
const report = { id: 'report', user_id: 'citizen', title: 'Waste', description: 'Litter',
  scale_level: 'small', obstruction_level: 'none', validation_status: 'pending_ai_validation' };
let updates;
beforeEach(() => {
  jest.clearAllMocks();
  updates = [];
  global.fetch = jest.fn();
  uploadFromBuffer.mockResolvedValue({ secure_url: 'https://evidence.test/photo' });
  from.mockImplementation(table => ({
    insert: jest.fn(input => ({ select: () => ({ single: async () => ({ data: table === 'reports' ? { ...report, ...input } : {}, error: null }) }) })),
    select: () => ({ eq: () => ({ single: async () => ({ data: { ...report }, error: null }) }) }),
    update: input => ({ eq: async () => { updates.push(input); return { error: null }; } })
  }));
});
afterEach(() => { global.fetch = originalFetch; jest.useRealTimers(); });
const response = () => ({ status: jest.fn().mockReturnThis(), json: jest.fn().mockReturnThis() });
const image = { buffer: Buffer.from('photo'), originalname: 'photo.jpg', mimetype: 'image/jpeg' };
const prediction = decision => ({ ok: true, status: 200, json: async () => ({
  predicted_class: decision === 'REJECTED' ? 'INVALID' : 'VALID', confidence: decision === 'REJECTED' ? .1 : .9, decision
}) });
const scenarios = [
  ['partial rejection', ['REJECTED', 'timeout'], 'manual_review'],
  ['partial approval', ['APPROVED', 'timeout'], 'manual_review'],
  ['complete outage', ['timeout', 'timeout'], 'manual_review'],
  ['complete rejection', ['REJECTED', 'REJECTED'], 'rejected'],
  ['complete approval', ['APPROVED', 'APPROVED'], 'approved']
];
const cases = [['create', createReport, 201], ['sync', syncReportMedia, 202]]
  .flatMap(([path, handler, status]) => scenarios.map(([label, decisions, expected]) => [path, label, handler, status, decisions, expected]));

test.each(cases)(
  '%s preserves evidence and citizen factors during %s', async (_, label, handler, status, decisions, expected) => {
    for (const decision of decisions) {
      if (decision === 'timeout') global.fetch.mockRejectedValueOnce(new Error('Classifier timed out'));
      else global.fetch.mockResolvedValueOnce(prediction(decision));
    }
    const res = response(), next = jest.fn();
    await handler({ body: { title: 'Waste', description: 'Litter', scale_level: 'small', obstruction_level: 'none' },
      params: { idempotency_key: 'key' }, user: { id: 'citizen' }, files: { image: [image, image] } }, res, next);
    for (let i = 0; i < 20 && !updates.length; i++) await new Promise(setImmediate);
    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(status);
    expect(uploadFromBuffer).toHaveBeenCalledTimes(2);
    expect(updates.at(-1)).toMatchObject({ validation_status: expected, scale_level: 'small', obstruction_level: 'none' });
    if (expected !== 'approved') expect(updates.at(-1)).not.toHaveProperty('severity_score');
  }
);

test('the classifier deadline covers reading the response body', async () => {
  jest.useFakeTimers();
  global.fetch.mockImplementation(async (_, { signal }) => ({ ok: true, status: 200,
    json: () => new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('Body timed out')))) }));
  const pending = classifyImage(Buffer.from('photo'));
  await jest.advanceTimersByTimeAsync(30001);
  await expect(pending).resolves.toMatchObject({ ok: false, error: 'Body timed out' });
});
