import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const execFileAsync = promisify(execFile);

/**
 * Extracts exactly 5 representative frames from a video buffer
 * @param {Buffer} videoBuffer - The video file buffer
 * @param {string} originalFilename - Original filename for extension detection
 * @returns {Promise<Array>} Array of 5 frame objects with buffer, index, timestamp, filename, mimeType
 */
export const extractVideoFrames = async (videoBuffer, originalFilename) => {
  console.log('[VIDEO-FRAME-EXTRACTION] START - filename:', originalFilename, 'buffer size:', videoBuffer.length);

  // Check ffmpeg availability
  try {
    await execFileAsync('ffmpeg', ['-version'], { timeout: 15000 });
    console.log('[VIDEO-FRAME-EXTRACTION] ffmpeg available');
  } catch (error) {
    console.error('[VIDEO-FRAME-EXTRACTION] ffmpeg not available:', error.message);
    throw new Error('ffmpeg is not available or not installed. Video frame extraction requires ffmpeg.');
  }

  let tempDir = null;

  try {
    // Create temporary directory
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'ecopin-video-'));
    console.log('[VIDEO-FRAME-EXTRACTION] temp dir created:', tempDir);

    // Determine video extension from original filename
    const ext = path.extname(originalFilename) || '.mp4';
    const videoFilename = `input${ext}`;
    const videoPath = path.join(tempDir, videoFilename);

    // Write video buffer to temp file
    await fs.writeFile(videoPath, videoBuffer);
    console.log('[VIDEO-FRAME-EXTRACTION] video written to:', videoPath);

    // Get video duration using ffprobe
    console.log('[VIDEO-FRAME-EXTRACTION] getting video duration...');
    const duration = await getVideoDuration(videoPath);
    console.log('[VIDEO-FRAME-EXTRACTION] duration detected:', duration, 'seconds');
    
    if (!duration || duration <= 0) {
      console.error('[VIDEO-FRAME-EXTRACTION] invalid duration:', duration);
      throw new Error('Could not determine video duration or invalid duration');
    }

    // Stay clear of EOF: 99% can fall after the final encoded frame.
    const timestamps = [0, .2, .4, .6, .8].map(fraction => duration * fraction);
    console.log('[VIDEO-FRAME-EXTRACTION] extracting frames at timestamps:', timestamps);

    // Extract frames at each timestamp
    const frames = [];
    for (let i = 0; i < timestamps.length; i++) {
      const timestamp = timestamps[i];
      const frameFilename = `frame_${i}.jpg`;
      const framePath = path.join(tempDir, frameFilename);

      console.log(`[VIDEO-FRAME-EXTRACTION] extracting frame ${i} at ${timestamp.toFixed(2)}s...`);

      // Extract single frame at timestamp
      await execFileAsync('ffmpeg', [
        '-nostdin', '-loglevel', 'error', '-protocol_whitelist', 'file,pipe',
        '-ss', timestamp.toString(),
        '-i', videoPath,
        '-frames:v', '1',
        '-pix_fmt', 'yuvj420p',
        '-q:v', '2', // High quality JPEG
        '-y', // Overwrite output files
        framePath
      ], { timeout: 20000 });

      // Read the extracted frame
      const frameBuffer = await fs.readFile(framePath);
      console.log(`[VIDEO-FRAME-EXTRACTION] frame ${i} extracted - size: ${frameBuffer.length} bytes`);

      frames.push({
        buffer: frameBuffer,
        index: i,
        timestamp: timestamp,
        filename: frameFilename,
        mimeType: 'image/jpeg'
      });
    }

    // Verify we got exactly 5 frames
    if (frames.length !== 5) {
      console.error(`[VIDEO-FRAME-EXTRACTION] Expected 5 frames but extracted ${frames.length}`);
      throw new Error(`Expected 5 frames but extracted ${frames.length}`);
    }

    console.log('[VIDEO-FRAME-EXTRACTION] SUCCESS - extracted 5 frames');
    return frames;

  } catch (error) {
    console.error('[VIDEO-FRAME-EXTRACTION] FAILED:', error.message);
    throw error;
  } finally {
    // Cleanup: always delete temp directory and contents
    if (tempDir) {
      try {
        await fs.rm(tempDir, { recursive: true, force: true });
        console.log('[VIDEO-FRAME-EXTRACTION] temp dir cleaned up');
      } catch (cleanupError) {
        console.error('[VIDEO-FRAME-EXTRACTION] Failed to cleanup temporary directory:', cleanupError);
      }
    }
  }
};

/**
 * Get video duration using ffprobe
 * @param {string} videoPath - Path to video file
 * @returns {Promise<number>} Duration in seconds
 */
const getVideoDuration = async (videoPath) => {
  try {
    const { stdout } = await execFileAsync('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      videoPath
    ], { timeout: 15000 });
    const duration = parseFloat(stdout.trim());
    return duration;
  } catch (error) {
    throw new Error(`Failed to get video duration: ${error.message}`);
  }
};
/** Probe actual uploaded bytes; client duration and MIME claims are not trusted. */
export async function inspectVideoBuffer(buffer) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'ecopin-video-check-'));
  try {
    const input = path.join(tempDir, 'input.media');
    await fs.writeFile(input, buffer);
    const { stdout } = await execFileAsync('ffprobe', [
      '-v', 'error', '-protocol_whitelist', 'file,pipe',
      '-show_entries', 'format=duration,format_name:stream=codec_type', '-of', 'json', input,
    ], { timeout: 15000, maxBuffer: 1024 * 1024 });
    const metadata = JSON.parse(stdout);
    const formats = (metadata.format?.format_name || '').split(',');
    if (!metadata.streams?.some(stream => stream.codec_type === 'video') ||
        !formats.some(format => ['mov', 'mp4', 'webm', 'matroska'].includes(format))) {
      throw new Error('A supported video stream is required');
    }
    const duration = Number(metadata.format?.duration);
    if (!Number.isFinite(duration) || duration <= 0) throw new Error('Invalid duration');
    return duration;
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}
