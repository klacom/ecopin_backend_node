import { CLASSIFIER_SERVICE_URL, VALIDATION_STATUS } from '../config/index.js';

// MANUAL_REVIEW confidence band — mirrors Exp 3.2 inference service config
const REVIEW_LO = parseFloat(process.env.EXP32_REVIEW_LO || '0.35');
const REVIEW_HI = parseFloat(process.env.EXP32_REVIEW_HI || '0.65');
const THRESHOLD  = parseFloat(process.env.EXP32_THRESHOLD  || '0.50');

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
            // Exp 3.2 fields
            decision: result.decision,
            in_review_zone: result.in_review_zone,
        };
    } catch (err) {
        clearTimeout(timeout);
        return {
            ok: false,
            error: err.message || String(err),
        };
    }
};

/**
 * Maps an Experiment 3.2 classifier result (VALID/INVALID + decision field)
 * to a VALIDATION_STATUS used by the EcoPin backend.
 *
 * The inference service already encodes the full decision logic including
 * the manual-review confidence zone, so we prefer its `decision` field.
 * A fallback using confidence + threshold is applied if the `decision` field
 * is absent (e.g. a legacy response).
 */
export const mapClassifierToValidation = (classifierResult) => {
    if (!classifierResult || !classifierResult.ok) {
        return {
            status: VALIDATION_STATUS.MANUAL_REVIEW,
            rejection_reason: null,
            auto_classification: null,
        };
    }

    const { predicted_class, confidence, decision } = classifierResult;

    // --- Exp 3.2 path: use the decision field emitted by the inference service ---
    if (decision) {
        if (decision === 'APPROVED') {
            return {
                status: VALIDATION_STATUS.APPROVED,
                rejection_reason: null,
                auto_classification: predicted_class,
            };
        }
        if (decision === 'REJECTED') {
            return {
                status: VALIDATION_STATUS.REJECTED,
                rejection_reason: 'Image classified as INVALID by automated validation (Exp 3.2).',
                auto_classification: predicted_class,
            };
        }
        // 'MANUAL_REVIEW' or any unexpected value → manual review
        return {
            status: VALIDATION_STATUS.MANUAL_REVIEW,
            rejection_reason: null,
            auto_classification: predicted_class,
        };
    }

    // --- Fallback path: binary VALID/INVALID without explicit decision field ---
    if (predicted_class === 'VALID' || predicted_class === 'INVALID') {
        const probValid = predicted_class === 'VALID' ? confidence : 1.0 - confidence;
        const inReviewZone = probValid >= REVIEW_LO && probValid <= REVIEW_HI;
        if (inReviewZone) {
            return {
                status: VALIDATION_STATUS.MANUAL_REVIEW,
                rejection_reason: null,
                auto_classification: predicted_class,
            };
        }
        if (probValid >= THRESHOLD) {
            return {
                status: VALIDATION_STATUS.APPROVED,
                rejection_reason: null,
                auto_classification: predicted_class,
            };
        }
        return {
            status: VALIDATION_STATUS.REJECTED,
            rejection_reason: 'Image classified as INVALID by automated validation.',
            auto_classification: predicted_class,
        };
    }

    // Unknown class
    return {
        status: VALIDATION_STATUS.MANUAL_REVIEW,
        rejection_reason: null,
        auto_classification: predicted_class,
    };
};
