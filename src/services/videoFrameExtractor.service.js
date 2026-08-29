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
    await execFileAsync('ffmpeg', ['-version']);
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

    // Calculate 5 sampling timestamps (0%, 25%, 50%, 75%, 100%)
    const timestamps = [
      0,
      duration * 0.25,
      duration * 0.5,
      duration * 0.75,
      duration * 0.99 // Use 99% to avoid potential end-of-file issues
    ];
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
        '-ss', timestamp.toString(),
        '-i', videoPath,
        '-frames:v', '1',
        '-q:v', '2', // High quality JPEG
        '-y', // Overwrite output files
        framePath
      ]);

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
    ]);
    const duration = parseFloat(stdout.trim());
    return duration;
  } catch (error) {
    throw new Error(`Failed to get video duration: ${error.message}`);
  }
};