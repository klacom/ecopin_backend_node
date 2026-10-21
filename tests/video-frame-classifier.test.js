import { jest } from '@jest/globals';
const classifyImage = jest.fn();
jest.unstable_mockModule('../src/services/classifierClient.service.js', () => ({ classifyImage }));
const { classifyVideoFrames } = await import('../src/services/videoFrameClassifier.service.js');
const frame = { buffer: Buffer.from('jpeg'), index: 0, timestamp: 1, filename: 'frame.jpg', mimeType: 'image/jpeg' };
test('frame classifier preserves explicit review decision and category for aggregation', async () => {
  classifyImage.mockResolvedValue({ ok: true, predicted_class: 'VALID', confidence: .95,
    predicted_category: 'flooding', decision: 'MANUAL_REVIEW' });
  const [result] = await classifyVideoFrames([frame]);
  expect(result).toMatchObject({ ok: true, decision: 'MANUAL_REVIEW', predicted_category: 'flooding', frameIndex: 0 });
});
test('failed inference is an explicit failed frame rather than an approval', async () => {
  classifyImage.mockRejectedValue(new Error('offline'));
  const [result] = await classifyVideoFrames([frame]);
  expect(result).toMatchObject({ ok: false, predicted_class: null, error: 'offline' });
});
test('missing input has a deliberate validation error', async () => {
  await expect(classifyVideoFrames(null)).rejects.toThrow('No frames provided');
});
