import { CLASSIFIER_SERVICE_URL, VALIDATION_STATUS } from '../config/index.js';

const HIGH_CONFIDENCE_THRESHOLD = parseFloat(process.env.CLASSIFIER_HIGH_CONFIDENCE || '0.70');
const ENVIRONMENTAL_CLASSES = ['flooding', 'pollution', 'waste'];

export const classifyImage = async (imageBuffer, originalName = 'image.jpg', mimeType = 'image/jpeg') => {
    if (!CLASSIFIER_SERVICE_URL) {
        throw new Error('CLASSIFIER_SERVICE_URL is not configured');
    }

    const controller = new AbortController();
    const timeoutMs = 30000;
    const timeout = setTimeout(() => controller.abort(), timeoutMs);

    try {
        const response = await fetch(`${CLASSIFIER_SERVICE_URL}/classify`, {
            method: 'POST',
            body: imageBuffer,
            headers: {
                'Content-Type': mimeType,
                'X-Filename': encodeURIComponent(originalName),
            },
            signal: controller.signal,
        });
        clearTimeout(timeout);

        if (!response.ok) {
            const errorText = await response.text().catch(() => '');
            throw new Error(`Classifier returned HTTP ${response.status}: ${errorText}`);
        }

        const result = await response.json();
        return {
            ok: true,
            predicted_class: result.predicted_class,
            confidence: result.confidence,
            probabilities: result.probabilities,
        };
    } catch (err) {
        clearTimeout(timeout);
        return {
            ok: false,
            error: err.message || String(err),
        };
    }
};

export const mapClassifierToValidation = (classifierResult) => {
    if (!classifierResult || !classifierResult.ok) {
        return {
            status: VALIDATION_STATUS.MANUAL_REVIEW,
            rejection_reason: null,
            auto_classification: null,
        };
    }

    const { predicted_class, confidence } = classifierResult;
    const isEnvironmental = ENVIRONMENTAL_CLASSES.includes(predicted_class);
    const isHighConfidence = confidence >= HIGH_CONFIDENCE_THRESHOLD;

    if (isEnvironmental && isHighConfidence) {
        return {
            status: VALIDATION_STATUS.APPROVED,
            rejection_reason: null,
            auto_classification: predicted_class,
        };
    }

    if (predicted_class === 'non_environmental' && isHighConfidence) {
        return {
            status: VALIDATION_STATUS.REJECTED,
            rejection_reason: 'Image classified as non-environmental by automated validation.',
            auto_classification: predicted_class,
        };
    }

    return {
        status: VALIDATION_STATUS.MANUAL_REVIEW,
        rejection_reason: null,
        auto_classification: predicted_class,
    };
};
