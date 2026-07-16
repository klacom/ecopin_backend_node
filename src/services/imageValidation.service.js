import * as tf from '@tensorflow/tfjs';
import * as mobilenet from '@tensorflow-models/mobilenet';
import * as cocoSsd from '@tensorflow-models/coco-ssd';
import sharp from 'sharp';
import { bufferToTensor } from './tfUtils.js';
import { IMAGE_VALIDATION_WEIGHTS, IMAGE_VALIDATION_THRESHOLDS, VALIDATION_STATUS, ISSUE_CATEGORIES, VALID_SCENES, INVALID_SCENES, OBJECT_KEYWORDS, SEVERE_VIOLATION_KEYWORDS } from '../config/index.js';

let mobilenetModel = null;
let cocoSsdModel = null;

// Load models lazily to save resources on startup
const loadModels = async () => {
    if (!mobilenetModel) {
        mobilenetModel = await mobilenet.load();
    }
    if (!cocoSsdModel) {
        cocoSsdModel = await cocoSsd.load();
    }
};

// Check for severe violations in image content
const checkSevereViolations = (mobilenetPredictions, cocoPredictions) => {
    const detectedViolations = [];
    
    // Check MobileNet predictions for severe content keywords
    const topPredictions = mobilenetPredictions.slice(0, 5).map(p => p.className.toLowerCase());
    
    for (const [category, keywords] of Object.entries(SEVERE_VIOLATION_KEYWORDS)) {
        for (const prediction of topPredictions) {
            if (keywords.some(keyword => prediction.includes(keyword))) {
                if (!detectedViolations.includes(category)) {
                    detectedViolations.push(category);
                }
                break;
            }
        }
    }
    
    // Check COCO-SSD objects for severe content indicators
    const detectedObjects = cocoPredictions.map(p => p.class.toLowerCase());
    const severeObjectKeywords = ['person', 'naked', 'blood', 'weapon', 'gun', 'knife'];
    
    for (const obj of detectedObjects) {
        if (severeObjectKeywords.some(keyword => obj.includes(keyword))) {
            // Additional context needed to determine if it's severe
            // For now, flag for manual review if person detected with other indicators
            if (detectedViolations.length > 0 && !detectedViolations.includes('manual_review')) {
                detectedViolations.push('manual_review');
            }
        }
    }
    
    return {
        hasSevereViolation: detectedViolations.length > 0,
        categories: detectedViolations
    };
};

// Image Validation 
export const validateImage = async (imageBuffer) => {
    const startTime = Date.now();
    await loadModels();

    // 1. Image Quality Validation
    const qualityScore = await checkImageQuality(imageBuffer);

    // 2. Prepare tensor for TF models
    const tensor = await bufferToTensor(imageBuffer, {
        resize: { width: 224, height: 224 }
    });

    // 3. Issue Relevance & Scene Context (MobileNet)
    const mobilenetPredictions = await mobilenetModel.classify(tensor);
    const { relevanceScore, sceneScore, predictedCategory } = analyzeMobileNet(mobilenetPredictions);

    // 4. Object Detection Evidence (COCO-SSD)
    const cocoPredictions = await cocoSsdModel.detect(tensor);
    const objectScore = analyzeCocoSsd(cocoPredictions, predictedCategory);

    // 5. Check for severe violations
    const severeViolationCheck = checkSevereViolations(mobilenetPredictions, cocoPredictions);

    // Cleanup tensor
    tensor.dispose();

    // If severe violation detected, immediately reject
    if (severeViolationCheck.hasSevereViolation) {
        console.log(`[ImageValidation] SEVERE VIOLATION DETECTED: ${severeViolationCheck.categories.join(', ')}`);
        return {
            score: 0,
            status: VALIDATION_STATUS.REJECTED,
            predictedCategory,
            severeViolation: true,
            severeCategories: severeViolationCheck.categories,
            details: {
                relevance: relevanceScore,
                objects: objectScore,
                scene: sceneScore,
                quality: qualityScore
            }
        };
    }

    // Calculate Final Score
    const finalScore = (
        (relevanceScore * IMAGE_VALIDATION_WEIGHTS.ISSUE_RELEVANCE) +
        (objectScore * IMAGE_VALIDATION_WEIGHTS.OBJECT_EVIDENCE) +
        (sceneScore * IMAGE_VALIDATION_WEIGHTS.SCENE_CONTEXT) +
        (qualityScore * IMAGE_VALIDATION_WEIGHTS.IMAGE_QUALITY)
    ) * 100;

    console.log(`[ImageValidation] Completed in ${Date.now() - startTime}ms. Score: ${finalScore.toFixed(2)}, Status: ${finalScore >= IMAGE_VALIDATION_THRESHOLDS.VALID ? 'VALID' : (finalScore >= IMAGE_VALIDATION_THRESHOLDS.REVIEW ? 'REVIEW' : 'REJECTED')}`);

    let status = VALIDATION_STATUS.REJECTED;
    if (finalScore >= IMAGE_VALIDATION_THRESHOLDS.VALID) {
        status = VALIDATION_STATUS.APPROVED;
    } else if (finalScore >= IMAGE_VALIDATION_THRESHOLDS.REVIEW) {
        status = VALIDATION_STATUS.MANUAL_REVIEW;
    }

    return {
        score: finalScore,
        status,
        predictedCategory,
        severeViolation: false,
        details: {
            relevance: relevanceScore,
            objects: objectScore,
            scene: sceneScore,
            quality: qualityScore
        }
    };
};

// Check image quality based on size and basic metadata
const checkImageQuality = async (buffer) => {
    const metadata = await sharp(buffer).metadata();

    // Check size
    if (metadata.width < 200 || metadata.height < 200) return 0;

    // TODO:
    // Check blur/exposure would require more complex stats (like Laplacian variance)
    // For now, simple metadata checks + MobileNet scene check handles documents/screenshots
    return 1.0;
};

// Relevancy and Scene Analysis using MobileNet
const analyzeMobileNet = (predictions) => {
    let relevanceScore = 0;
    let sceneScore = 0.5; // Default neutral
    let predictedCategory = 'others';

    const topPrediction = predictions[0].className.toLowerCase();

    // Issue Relevance
    for (const [category, keywords] of Object.entries(ISSUE_CATEGORIES)) {
        if (keywords.some(k => topPrediction.includes(k))) {
            relevanceScore = 1.0;
            predictedCategory = category;
            break;
        }
    }

    // Scene Context
    if (VALID_SCENES.some(s => topPrediction.includes(s))) {
        sceneScore = 1.0;
    } else if (INVALID_SCENES.some(s => topPrediction.includes(s))) {
        sceneScore = 0;
    }

    return { relevanceScore, sceneScore, predictedCategory };
};

// Object Detection Evidence using COCO-SSD
const analyzeCocoSsd = (predictions, predictedCategory) => {
    if (predictions.length === 0) return 0.2; // Some evidence is better than none

    const relevantObjects = OBJECT_KEYWORDS[predictedCategory] || [];
    const hasRelevantObject = predictions.some(p => relevantObjects.includes(p.class));

    return hasRelevantObject ? 1.0 : 0.5;
};

// Eagerly load models on startup
loadModels().catch(err => console.error("Failed to eager load models:", err));