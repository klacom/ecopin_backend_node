import { jest } from '@jest/globals';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const single = jest.fn();
const query = { maybeSingle: single, order: jest.fn().mockReturnThis(), limit: jest.fn().mockReturnThis() };
const select = jest.fn(() => query);
const from = jest.fn(() => ({ select }));
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: { from } }));
const { getReportVideoPolicy, validateVideoMaximum, validateReportVideo, getReportVideoPolicyHandler } =
  await import('../src/services/report-video-policy.service.js');
const { inspectVideoBuffer, extractVideoFrames } = await import('../src/services/videoFrameExtractor.service.js');
const { aggregateVideoValidation } = await import('../src/services/videoFrameAggregator.service.js');
const { VALIDATION_STATUS } = await import('../src/config/index.js');

const response = () => ({ code: 200, headers: {}, status(code) { this.code = code; return this; },
  set(key, value) { this.headers[key] = value; return this; }, json(body) { this.body = body; return this; } });
let directory;
const videos = new Map();
beforeAll(async () => {
  directory = await fs.mkdtemp(path.join(os.tmpdir(), 'ecopin-video-test-'));
  for (const seconds of [4.9, 5, 7, 8, 8.1, 8.2, 10, 10.026, 10.1, 10.2]) {
    const file = path.join(directory, `${seconds}.mp4`);
    execFileSync('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', `color=c=green:s=64x64:r=${seconds === 10.026 ? 500 : 10}`,
      '-t', String(seconds), '-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', file], { timeout: 20000 });
    videos.set(seconds, await fs.readFile(file));
  }
}, 60000);
afterAll(async () => { if (directory) await fs.rm(directory, { recursive: true, force: true }); });
beforeEach(() => { single.mockResolvedValue({ data: { report_video_max_seconds: 8 }, error: null }); });

test('admin maximum accepts only integers from 5 to 10', () => {
  for (const value of [5, 7, 10]) expect(validateVideoMaximum(value)).toBe(true);
  for (const value of [4, 11, 7.5, '8', null, NaN, Infinity]) expect(validateVideoMaximum(value)).toBe(false);
});
test('citizen policy reads the database, exposes only limits, and avoids caching', async () => {
  const res = response();
  await getReportVideoPolicyHandler({}, res);
  expect(res.body).toEqual({ min_seconds: 5, max_seconds: 8 });
  expect(query.limit).toHaveBeenCalledWith(1);
  expect(query.order).toHaveBeenCalledWith('updated_at', { ascending: false, nullsFirst: false });
  expect(res.headers['Cache-Control']).toBe('no-store');
  single.mockResolvedValue({ data: { report_video_max_seconds: 6 }, error: null });
  expect(await getReportVideoPolicy()).toEqual({ min_seconds: 5, max_seconds: 6 });
});
test.each([4.9, 8.2, 10.2])('rejects actual %ss bytes despite a valid claimed duration', async seconds => {
  const next = jest.fn(), res = response();
  await validateReportVideo({ body: { duration: 5 }, files: { video: [{ buffer: videos.get(seconds) }] } }, res, next);
  expect(res.code).toBe(422); expect(next).not.toHaveBeenCalled();
});
test.each([5, 7, 8, 8.1])('accepts a real %ss clip within the saved limits', async seconds => {
  const next = jest.fn(), res = response();
  await validateReportVideo({ files: { video: [{ buffer: videos.get(seconds) }] } }, res, next);
  expect(next).toHaveBeenCalledTimes(1);
});
test('admin update to 10 seconds changes validation on the next request', async () => {
  single.mockResolvedValue({ data: { report_video_max_seconds: 10 }, error: null });
  const next = jest.fn();
  await validateReportVideo({ files: { video: [{ buffer: videos.get(10) }] } }, response(), next);
  expect(next).toHaveBeenCalledTimes(1);
});
test.each([10.026, 10.1])('accepts a real %ss clip at the nominal 10-second recorder limit', async seconds => {
  single.mockResolvedValue({ data: { report_video_max_seconds: 10 }, error: null });
  const duration = await inspectVideoBuffer(videos.get(seconds));
  expect(duration).toBeCloseTo(seconds, 3);
  const next = jest.fn();
  await validateReportVideo({ files: { video: [{ buffer: videos.get(seconds) }] } }, response(), next);
  expect(next).toHaveBeenCalledTimes(1);
});
test('a nominal 10-second recording still rejects a real 10.2-second clip', async () => {
  single.mockResolvedValue({ data: { report_video_max_seconds: 10 }, error: null });
  const next = jest.fn(), res = response();
  await validateReportVideo({ files: { video: [{ buffer: videos.get(10.2) }] } }, res, next);
  expect(res.code).toBe(422); expect(next).not.toHaveBeenCalled();
});
test('missing database policy fails closed for videos but not photo-only requests', async () => {
  single.mockResolvedValue({ data: null, error: { message: 'offline' } });
  const next = jest.fn(), res = response();
  await validateReportVideo({ files: { video: [{ buffer: videos.get(5) }] } }, res, next);
  expect(res.code).toBe(503); expect(next).not.toHaveBeenCalled();
  await validateReportVideo({ files: { image: [{}] } }, response(), next);
  expect(next).toHaveBeenCalledTimes(1);
});
test('corrupt files and renamed audio cannot masquerade as video', async () => {
  await expect(inspectVideoBuffer(Buffer.from('not a movie'))).rejects.toThrow();
  const audio = path.join(directory, 'audio.mp4');
  execFileSync('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440',
    '-t', '5', '-vn', '-c:a', 'aac', '-y', audio], { timeout: 20000 });
  await expect(inspectVideoBuffer(await fs.readFile(audio))).rejects.toThrow('video stream');
});
test('real video produces five distinct timestamped JPEG frames', async () => {
  const frames = await extractVideoFrames(videos.get(5), 'synthetic.mp4');
  expect(frames).toHaveLength(5);
  expect(new Set(frames.map(frame => frame.timestamp)).size).toBe(5);
  for (const frame of frames) expect(frame.buffer.subarray(0, 2)).toEqual(Buffer.from([0xff, 0xd8]));
});
const frame = (decision = 'APPROVED') => ({ ok: true, predicted_class: 'VALID',
  predicted_category: 'flooding', decision, confidence: .95 });
test('video AI approval preserves the actual environmental category', () => {
  const result = aggregateVideoValidation(Array.from({ length: 5 }, () => frame()));
  expect(result.validation_status).toBe(VALIDATION_STATUS.APPROVED);
  expect(result.dominant_class).toBe('flooding');
});
test('manual-review and unknown classifier decisions cannot become auto-approved', () => {
  for (const decision of ['MANUAL_REVIEW', 'UNEXPECTED']) {
    expect(aggregateVideoValidation(Array.from({ length: 5 }, () => frame(decision))).validation_status)
      .toBe(VALIDATION_STATUS.MANUAL_REVIEW);
  }
});
test('explicit rejection overrides binary VALID, and failed inference remains manual', () => {
  expect(aggregateVideoValidation(Array.from({ length: 5 }, () => frame('REJECTED'))).validation_status)
    .toBe(VALIDATION_STATUS.REJECTED);
  expect(aggregateVideoValidation([{ ok: false }]).validation_status).toBe(VALIDATION_STATUS.MANUAL_REVIEW);
});
