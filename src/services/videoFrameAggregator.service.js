import { VALIDATION_STATUS } from '../config/index.js';

// Aggregation thresholds - configurable for tuning
const MIN_SUCCESSFUL_FRAMES = 3;
const ENVIRONMENTAL_RATIO_APPROVE = 0.60;
const DOMINANT_CLASS_RATIO_APPROVE = 0.50;
const AVG_CONFIDENCE_APPROVE = 0.60;
const ENVIRONMENTAL_RATIO_REJECT = 0.40;

// Environmental classes
const ENVIRONMENTAL_CLASSES = ['waste', 'pollution', 'flooding'];

/**
 * Aggregates 5 frame classification results into a single video validation result
 * @param {Array} frameResults - Array of frame classification results from videoFrameClassifier
 * @returns {Object} Aggregated validation result with status and metrics
 */
export const aggregateVideoValidation = (frameResults) => {
  console.log('[VIDEO-AGGREGATION] START - processing', frameResults.length, 'frame results');
  
  if (!frameResults || !Array.isArray(frameResults) || frameResults.length === 0) {
    console.error('[VIDEO-AGGREGATION] No frame results provided');
    return {
      validation_status: VALIDATION_STATUS.MANUAL_REVIEW,
      dominant_class: null,
      environmental_frame_ratio: 0,
      dominant_class_ratio: 0,
      average_environmental_confidence: 0,
      total_frames: 0,
      successful_frames: 0,
      failed_frames: 0,
      environmental_frames: 0,
      non_environmental_frames: 0,
      frame_results: [],
      rejection_reason: 'No frame results provided'
    };
  }

  const totalFrames = frameResults.length;
  
  // Separate successful and failed frames
  const successfulFrames = frameResults.filter(f => f.ok && f.predicted_class);
  const failedFrames = frameResults.filter(f => !f.ok || !f.predicted_class);
  
  const successfulCount = successfulFrames.length;
  const failedCount = failedFrames.length;
  
  console.log(`[VIDEO-AGGREGATION] Frame analysis - total: ${totalFrames}, successful: ${successfulCount}, failed: ${failedCount}`);

  // Insufficient successful frames
  if (successfulCount < MIN_SUCCESSFUL_FRAMES) {
    console.log(`[VIDEO-AGGREGATION] MANUAL_REVIEW - insufficient successful frames (${successfulCount}/${MIN_SUCCESSFUL_FRAMES})`);
    return {
      validation_status: VALIDATION_STATUS.MANUAL_REVIEW,
      dominant_class: null,
      environmental_frame_ratio: 0,
      dominant_class_ratio: 0,
      average_environmental_confidence: 0,
      total_frames: totalFrames,
      successful_frames: successfulCount,
      failed_frames: failedCount,
      environmental_frames: 0,
      non_environmental_frames: 0,
      frame_results: frameResults,
      rejection_reason: `Insufficient successful classifications (${successfulCount}/${totalFrames})`
    };
  }

  // Count environmental vs non-environmental frames
  const environmentalFrames = successfulFrames.filter(f => 
    ENVIRONMENTAL_CLASSES.includes(f.predicted_class)
  );
  const nonEnvironmentalFrames = successfulFrames.filter(f => 
    !ENVIRONMENTAL_CLASSES.includes(f.predicted_class)
  );

  const environmentalCount = environmentalFrames.length;
  const nonEnvironmentalCount = nonEnvironmentalFrames.length;
  const environmentalRatio = environmentalCount / successfulCount;
  
  console.log(`[VIDEO-AGGREGATION] Environmental analysis - env: ${environmentalCount}, non-env: ${nonEnvironmentalCount}, ratio: ${environmentalRatio.toFixed(2)}`);

  // All frames are non-environmental
  if (environmentalCount === 0) {
    console.log('[VIDEO-AGGREGATION] REJECTED - all frames are non-environmental');
    return {
      validation_status: VALIDATION_STATUS.REJECTED,
      dominant_class: 'non_environmental',
      environmental_frame_ratio: 0,
      dominant_class_ratio: 0,
      average_environmental_confidence: 0,
      total_frames: totalFrames,
      successful_frames: successfulCount,
      failed_frames: failedCount,
      environmental_frames: environmentalCount,
      non_environmental_frames: nonEnvironmentalCount,
      frame_results: frameResults,
      rejection_reason: 'All successfully classified frames are non-environmental'
    };
  }

  // Find dominant environmental class
  const classCounts = {};
  environmentalFrames.forEach(frame => {
    const className = frame.predicted_class;
    classCounts[className] = (classCounts[className] || 0) + 1;
  });

  // Find class with maximum count (tie-breaker: alphabetical)
  let dominantClass = null;
  let maxCount = 0;
  Object.entries(classCounts).forEach(([className, count]) => {
    if (count > maxCount || (count === maxCount && className < dominantClass)) {
      maxCount = count;
      dominantClass = className;
    }
  });

  const dominantClassRatio = maxCount / environmentalCount;

  // Calculate average environmental confidence
  const totalConfidence = environmentalFrames.reduce((sum, f) => sum + (f.confidence || 0), 0);
  const avgConfidence = totalConfidence / environmentalCount;
  
  console.log(`[VIDEO-AGGREGATION] Dominant class: ${dominantClass} (${maxCount}/${environmentalCount}), avg confidence: ${avgConfidence.toFixed(3)}`);

  // Apply approval thresholds
  const meetsMinFrames = successfulCount >= MIN_SUCCESSFUL_FRAMES;
  const meetsEnvironmentalRatio = environmentalRatio >= ENVIRONMENTAL_RATIO_APPROVE;
  const meetsDominantClassRatio = dominantClassRatio >= DOMINANT_CLASS_RATIO_APPROVE;
  const meetsConfidenceThreshold = avgConfidence >= AVG_CONFIDENCE_APPROVE;
  
  console.log(`[VIDEO-AGGREGATION] Threshold checks - minFrames: ${meetsMinFrames}, envRatio: ${meetsEnvironmentalRatio}, domRatio: ${meetsDominantClassRatio}, confidence: ${meetsConfidenceThreshold}`);

  if (meetsMinFrames && meetsEnvironmentalRatio && meetsDominantClassRatio && meetsConfidenceThreshold) {
    console.log(`[VIDEO-AGGREGATION] APPROVED - status: APPROVED, dominant: ${dominantClass}`);
    return {
      validation_status: VALIDATION_STATUS.APPROVED,
      dominant_class: dominantClass,
      environmental_frame_ratio: environmentalRatio,
      dominant_class_ratio: dominantClassRatio,
      average_environmental_confidence: avgConfidence,
      total_frames: totalFrames,
      successful_frames: successfulCount,
      failed_frames: failedCount,
      environmental_frames: environmentalCount,
      non_environmental_frames: nonEnvironmentalCount,
      frame_results: frameResults,
      rejection_reason: null
    };
  }

  // Apply rejection thresholds
  if (environmentalRatio <= ENVIRONMENTAL_RATIO_REJECT) {
    console.log(`[VIDEO-AGGREGATION] REJECTED - environmental ratio too low (${environmentalRatio.toFixed(2)} <= ${ENVIRONMENTAL_RATIO_REJECT})`);
    return {
      validation_status: VALIDATION_STATUS.REJECTED,
      dominant_class: dominantClass,
      environmental_frame_ratio: environmentalRatio,
      dominant_class_ratio: dominantClassRatio,
      average_environmental_confidence: avgConfidence,
      total_frames: totalFrames,
      successful_frames: successfulCount,
      failed_frames: failedCount,
      environmental_frames: environmentalCount,
      non_environmental_frames: nonEnvironmentalCount,
      frame_results: frameResults,
      rejection_reason: `Environmental frame ratio (${environmentalRatio.toFixed(2)}) at or below rejection threshold (${ENVIRONMENTAL_RATIO_REJECT})`
    };
  }

  // Manual review for everything else
  console.log('[VIDEO-AGGREGATION] MANUAL_REVIEW - thresholds not met for approval/rejection');
  return {
    validation_status: VALIDATION_STATUS.MANUAL_REVIEW,
    dominant_class: dominantClass,
    environmental_frame_ratio: environmentalRatio,
    dominant_class_ratio: dominantClassRatio,
    average_environmental_confidence: avgConfidence,
    total_frames: totalFrames,
    successful_frames: successfulCount,
    failed_frames: failedCount,
    environmental_frames: environmentalCount,
    non_environmental_frames: nonEnvironmentalCount,
    frame_results: frameResults,
    rejection_reason: null
  };
};