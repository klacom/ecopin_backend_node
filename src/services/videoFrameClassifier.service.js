import { classifyImage } from './classifierClient.service.js';

/**
 * Classifies multiple video frames in parallel using the existing image classifier
 * @param {Array} frames - Array of frame objects from videoFrameExtractor
 * @returns {Promise<Array>} Array of classification results with frame metadata
 */
export const classifyVideoFrames = async (frames) => {
  console.log('[VIDEO-FRAME-CLASSIFIER] START - classifying', frames.length, 'frames');
  
  if (!frames || !Array.isArray(frames) || frames.length === 0) {
    console.error('[VIDEO-FRAME-CLASSIFIER] No frames provided');
    throw new Error('No frames provided for classification');
  }

  // Classify all frames in parallel
  const classificationPromises = frames.map(async (frame) => {
    console.log(`[VIDEO-FRAME-CLASSIFIER] Frame ${frame.index} START - timestamp: ${frame.timestamp.toFixed(2)}s`);
    
    try {
      const result = await classifyImage(
        frame.buffer,
        frame.filename,
        frame.mimeType
      );
      
      if (result.ok) {
        console.log(`[VIDEO-FRAME-CLASSIFIER] Frame ${frame.index} SUCCESS - class: ${result.predicted_class}, confidence: ${result.confidence?.toFixed(3)}`);
      } else {
        console.error(`[VIDEO-FRAME-CLASSIFIER] Frame ${frame.index} FAILED - error: ${result.error}`);
      }
      
      return {
        frameIndex: frame.index,
        timestamp: frame.timestamp,
        filename: frame.filename,
        ok: result.ok,
        predicted_class: result.predicted_class,
        confidence: result.confidence,
        probabilities: result.probabilities,
        error: result.error || null
      };
    } catch (error) {
      console.error(`[VIDEO-FRAME-CLASSIFIER] Frame ${frame.index} EXCEPTION - error: ${error.message}`);
      return {
        frameIndex: frame.index,
        timestamp: frame.timestamp,
        filename: frame.filename,
        ok: false,
        predicted_class: null,
        confidence: null,
        probabilities: null,
        error: error.message || 'Unknown classification error'
      };
    }
  });

  // Use Promise.allSettled to ensure all frames are processed even if some fail
  const settledResults = await Promise.allSettled(classificationPromises);

  // Map settled results to final format
  const results = settledResults.map((settled, index) => {
    if (settled.status === 'fulfilled') {
      return settled.value;
    } else {
      // Handle Promise rejection (shouldn't happen with try/catch above, but safe fallback)
      console.error(`[VIDEO-FRAME-CLASSIFIER] Frame ${index} PROMISE REJECTED - error: ${settled.reason?.message}`);
      return {
        frameIndex: frames[index].index,
        timestamp: frames[index].timestamp,
        filename: frames[index].filename,
        ok: false,
        predicted_class: null,
        confidence: null,
        probabilities: null,
        error: settled.reason?.message || 'Classification promise rejected'
      };
    }
  });

  const successful = results.filter(r => r.ok).length;
  const failed = results.filter(r => !r.ok).length;
  console.log(`[VIDEO-FRAME-CLASSIFIER] COMPLETE - successful: ${successful}, failed: ${failed}`);
  
  return results;
};