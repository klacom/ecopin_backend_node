import * as tf from '@tensorflow/tfjs';
import * as mobilenet from '@tensorflow-models/mobilenet';
import * as cocoSsd from '@tensorflow-models/coco-ssd';
import sharp from 'sharp';
import { bufferToTensor } from './tfUtils.js';
import { IMAGE_VALIDATION_WEIGHTS, IMAGE_VALIDATION_THRESHOLDS, VALIDATION_STATUS } from '../config/index.js';

let mobilenetModel = null;
let cocoSsdModel = null;

/**
 * Load models lazily to save resources on startup
 */
const loadModels = async () => {
    if (!mobilenetModel) {
        mobilenetModel = await mobilenet.load();
    }
    if (!cocoSsdModel) {
        cocoSsdModel = await cocoSsd.load();
    }
};

/**
 * Environmental Issue Categories and related keywords for MobileNet
 */
const ISSUE_CATEGORIES = {
    waste: ['garbage', 'trash', 'litter', 'plastic', 'debris', 'dump', 'waste', 'bottle', 'can'],
    flooding: ['flood', 'water', 'submerged', 'river', 'inundation', 'lake'],
    pollution: ['smoke', 'smog', 'oil', 'slick', 'dirty', 'pollution', 'factory', 'industrial'],
};

/**
 * Valid Scene Keywords for MobileNet
 */
const VALID_SCENES = ['street', 'road', 'river', 'park', 'beach', 'canal', 'residential', 'outdoor', 'ground', 'pavement'];

/**
 * Invalid Scene Keywords for MobileNet
 */
const INVALID_SCENES = ['bedroom', 'living room', 'kitchen', 'office', 'screenshot', 'document', 'meme', 'drawing', 'cartoon'];

/**
 * Object Detection Keywords for COCO-SSD
 */
const OBJECT_KEYWORDS = {
    waste: ['bottle', 'cup', 'handbag', 'suitcase', 'backpack'], // COCO-SSD limited set, mapping trash-like items
    flooding: ['boat', 'car', 'truck', 'bus'], // Items often submerged or in water
    pollution: ['train', 'truck', 'car'] // Associated with emissions/oil
};

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

    // Cleanup tensor
    tensor.dispose();

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
        status = VALIDATION_STATUS.AUTOMATICALLY_VALID;
    } else if (finalScore >= IMAGE_VALIDATION_THRESHOLDS.REVIEW) {
        status = VALIDATION_STATUS.MANUAL_REVIEW;
    }

    return {
        score: finalScore,
        status,
        predictedCategory,
        details: {
            relevance: relevanceScore,
            objects: objectScore,
            scene: sceneScore,
            quality: qualityScore
        }
    };
};

const checkImageQuality = async (buffer) => {
    const metadata = await sharp(buffer).metadata();

    // Check size
    if (metadata.width < 200 || metadata.height < 200) return 0;

    // Check blur/exposure would require more complex stats (like Laplacian variance)
    // For now, simple metadata checks + MobileNet scene check handles documents/screenshots
    return 1.0;
};

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

const analyzeCocoSsd = (predictions, predictedCategory) => {
    if (predictions.length === 0) return 0.2; // Some evidence is better than none

    const relevantObjects = OBJECT_KEYWORDS[predictedCategory] || [];
    const hasRelevantObject = predictions.some(p => relevantObjects.includes(p.class));

    return hasRelevantObject ? 1.0 : 0.5;
};

// Eagerly load models on startup
loadModels().catch(err => console.error("Failed to eager load models:", err));
