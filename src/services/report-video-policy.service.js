import { getCurrentSystemSettings } from './system-settings.service.js';
import { supabaseAdmin } from '../config/supabase.config.js';
import { inspectVideoBuffer } from './videoFrameExtractor.service.js';

export const MIN_VIDEO_SECONDS = 5;
// Match the app's 100ms allowance for recorder stop/container timing overhead.
const MAX_DURATION_TOLERANCE_SECONDS = 0.1;
export function validateVideoMaximum(value) {
  return Number.isInteger(value) && value >= MIN_VIDEO_SECONDS && value <= 10;
}

export async function getReportVideoPolicy(client = supabaseAdmin) {
  const { data, error } = await getCurrentSystemSettings(client, 'report_video_max_seconds');
  if (error || !validateVideoMaximum(data?.report_video_max_seconds)) {
    const failure = new Error('Video limits are unavailable. Try again or attach photos instead.');
    failure.status = 503;
    throw failure;
  }
  return { min_seconds: MIN_VIDEO_SECONDS, max_seconds: data.report_video_max_seconds };
}

export async function getReportVideoPolicyHandler(req, res) {
  try {
    res.set('Cache-Control', 'no-store');
    return res.json(await getReportVideoPolicy());
  } catch (error) {
    return res.status(503).json({ message: 'Video limits are unavailable. Please try again.' });
  }
}

// Run after multipart parsing and before accepting/storing any submitted video.
export async function validateReportVideo(req, res, next) {
  const video = req.files?.video?.[0];
  if (!video) return next();
  try {
    const policy = await getReportVideoPolicy();
    let duration;
    try {
      duration = await inspectVideoBuffer(video.buffer);
    } catch {
      return res.status(422).json({ message: 'This video could not be read. Record a valid MP4, MOV, or WEBM video.' });
    }
    if (!Number.isFinite(duration) || duration < policy.min_seconds || duration > policy.max_seconds + MAX_DURATION_TOLERANCE_SECONDS) {
      return res.status(422).json({
        message: `Record a video between ${policy.min_seconds} and ${policy.max_seconds} seconds long.`,
        ...policy,
      });
    }
    return next();
  } catch (error) {
    return res.status(error.status || 503).json({ message: 'Video limits are unavailable. Please try again.' });
  }
}
