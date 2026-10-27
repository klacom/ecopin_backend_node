import { CLASSIFIER_SERVICE_URL, USE_AWS_CLASSIFIER, AWS_CLASSIFIER_URL, VALIDATION_STATUS } from '../config/index.js';
import sharp from 'sharp';

// MANUAL_REVIEW confidence band — mirrors Exp 3.2 inference service config
const REVIEW_LO = parseFloat(process.env.EXP32_REVIEW_LO || '0.35');
const REVIEW_HI = parseFloat(process.env.EXP32_REVIEW_HI || '0.65');
const THRESHOLD  = parseFloat(process.env.EXP32_THRESHOLD  || '0.50');

// ── Logging helpers ───────────────────────────────────────────────────────────
const _tag = '[ClassifierClient]';
const _log  = (...a) => console.log (_tag, ...a);
const _warn = (...a) => console.warn (_tag, ...a);
const _err  = (...a) => console.error(_tag, ...a);

export const classifyImage = async (imageBuffer, originalName = 'image.jpg', mimeType = 'image/jpeg') => {
    let endpoint;
    let fetchOptions;

    if (USE_AWS_CLASSIFIER) {
        if (!AWS_CLASSIFIER_URL) {
            _err('AWS_CLASSIFIER_URL is not configured — cannot classify image');
            throw new Error('AWS_CLASSIFIER_URL is not configured');
        }
        endpoint = AWS_CLASSIFIER_URL;
        
        // Compress image to avoid AWS Lambda 6MB payload limit
        let processedBuffer = imageBuffer;
        try {
            processedBuffer = await sharp(imageBuffer)
                .resize(800, 800, { fit: 'inside', withoutEnlargement: true })
                .jpeg({ quality: 85 })
                .toBuffer();
            _log(`  [AWS] Compressed payload from ${(imageBuffer.byteLength / 1024).toFixed(1)} KB to ${(processedBuffer.byteLength / 1024).toFixed(1)} KB`);
        } catch (e) {
            _warn('  [AWS] Failed to compress image with sharp, using original buffer', e.message);
        }

        fetchOptions = {
            method: 'POST',
            body: JSON.stringify({ image: processedBuffer.toString('base64') }),
            headers: { 'Content-Type': 'application/json' }
        };
    } else {
        if (!CLASSIFIER_SERVICE_URL) {
            _err('CLASSIFIER_SERVICE_URL is not configured — cannot classify image');
            throw new Error('CLASSIFIER_SERVICE_URL is not configured');
        }
        endpoint = `${CLASSIFIER_SERVICE_URL}/classify`;
        fetchOptions = {
            method: 'POST',
            body: imageBuffer,
            headers: {
                'Content-Type': mimeType,
                'X-Filename': encodeURIComponent(originalName),
            }
        };
    }

    const sizeKB   = (imageBuffer.byteLength / 1024).toFixed(1);

    // ── REQUEST ──────────────────────────────────────────────────────────────
    _log('──────────────────────────────────────────────');
    _log(`→ REQUEST  POST (${USE_AWS_CLASSIFIER ? 'AWS' : 'LOCAL'})`, endpoint);
    _log('  file    :', originalName);
    _log('  mime    :', mimeType);
    _log('  size    :', `${sizeKB} KB  (${imageBuffer.byteLength} bytes)`);

    const t0         = Date.now();
    const controller = new AbortController();
    const timeoutMs  = 30000;
    const timeout    = setTimeout(() => controller.abort(), timeoutMs);

    try {
        fetchOptions.signal = controller.signal;
        const response = await fetch(endpoint, fetchOptions);
        clearTimeout(timeout);

        const elapsedMs = Date.now() - t0;

        // ── HTTP-LEVEL RESPONSE ───────────────────────────────────────────
        _log('← RESPONSE status :', response.status, response.statusText, `(${elapsedMs}ms)`);

        if (!response.ok) {
            const errorText = await response.text().catch(() => '');
            _err('  Classifier error body:', errorText);
            throw new Error(`Classifier returned HTTP ${response.status}: ${errorText}`);
        }

        const result = await response.json();

        // ── RESPONSE PAYLOAD ─────────────────────────────────────────────
        _log('  predicted_class    :', result.predicted_class);
        _log('  confidence (valid) :', result.confidence);
        _log('  probabilities      :', JSON.stringify(result.probabilities));
        _log('  decision           :', result.decision);
        _log('  in_review_zone     :', result.in_review_zone);
        _log('  predicted_category :', result.predicted_category ?? '(null — rejected)');
        _log('  predicted_scale    :', result.predicted_scale ?? '(null)');
        _log('  predicted_obstruction :', result.predicted_obstruction ?? '(null)');
        _log('  inference_ms       :', result.inference_ms ?? 'n/a');
        _log('──────────────────────────────────────────────');

        return {
            ok: true,
            predicted_class:           result.predicted_class,
            confidence:                result.confidence,
            probabilities:             result.probabilities,
            // Exp 3.2 fields
            decision:                  result.decision,
            in_review_zone:            result.in_review_zone,
            // Zero-shot category (null when image is REJECTED)
            predicted_category:        result.predicted_category ?? null,
            // Zero-shot scale (null when image is REJECTED)
            predicted_scale:           result.predicted_scale ?? null,
            scale_confidence:          result.scale_confidence ?? null,
            scale_probabilities:       result.scale_probabilities ?? null,
            // Zero-shot obstruction (null when image is REJECTED)
            predicted_obstruction:     result.predicted_obstruction ?? null,
            obstruction_confidence:    result.obstruction_confidence ?? null,
            obstruction_probabilities: result.obstruction_probabilities ?? null,
        };
    } catch (err) {
        clearTimeout(timeout);
        const elapsedMs = Date.now() - t0;
        _err(`  FAILED after ${elapsedMs}ms :`, err.message);
        _log('──────────────────────────────────────────────');
        return {
            ok: false,
            error: err.message || String(err),
        };
    }
};

export const ALLOWED_CLASSIFIER_CATEGORIES = Object.freeze([
    'waste',
    'flooding',
    'pollution',
    'infrastructure',
    'illegal_logging',
    'others'
]);

export const ALLOWED_PREDICTED_CLASSES = Object.freeze([
    'VALID',
    'INVALID',
    'waste',
    'pollution',
    'flooding'
]);

function sanitizeCategory(category) {
    if (typeof category !== 'string') return null;
    const normalized = category.trim().toLowerCase();
    return ALLOWED_CLASSIFIER_CATEGORIES.includes(normalized) ? normalized : null;
}

function sanitizePredictedClass(predictedClass) {
    if (typeof predictedClass !== 'string') return null;
    const normalized = predictedClass.trim();
    return ALLOWED_PREDICTED_CLASSES.includes(normalized) ? normalized : null;
}

/**
 * Maps an Experiment 3.2 classifier result (VALID/INVALID + decision field)
 * to a VALIDATION_STATUS used by the EcoPin backend.
 *
 * Model outputs are treated as untrusted data:
 * - decision is strictly allowlisted to APPROVED, REJECTED, or MANUAL_REVIEW
 * - image-derived scale/obstruction are ignored; citizen inputs supply these factors
 * - predicted_category is validated against ALLOWED_CLASSIFIER_CATEGORIES
 * - auto_classification is validated against ALLOWED_PREDICTED_CLASSES
 * - arbitrary strings or anomalous structures safely default to MANUAL_REVIEW
 */
export const mapClassifierToValidation = (classifierResult) => {
    if (!classifierResult || !classifierResult.ok) {
        _warn('mapClassifierToValidation: result not ok — defaulting to MANUAL_REVIEW');
        _warn('  result:', JSON.stringify(classifierResult));
        return {
            status: VALIDATION_STATUS.MANUAL_REVIEW,
            rejection_reason: null,
            auto_classification: null,
            predicted_category: null,
        };
    }

    const { predicted_class, confidence, decision } = classifierResult;
    const safeCategory = sanitizeCategory(classifierResult.predicted_category);
    const safeAutoClass = sanitizePredictedClass(predicted_class);

    _log('mapClassifierToValidation:');
    _log('  predicted_class    :', predicted_class);
    _log('  confidence         :', confidence);
    _log('  decision           :', decision ?? '(none — using fallback path)');
    _log('  predicted_category :', safeCategory ?? '(null)');

    // --- Exp 3.2 path: use the decision field emitted by the inference service ---
    if (decision) {
        if (decision === 'APPROVED') {
            const mapped = {
                status: VALIDATION_STATUS.APPROVED,
                rejection_reason: null,
                auto_classification: safeAutoClass,
                predicted_category: safeCategory,
                predicted_scale: null,
                scale_confidence: null,
                scale_probabilities: null,
                predicted_obstruction: null,
                obstruction_confidence: null,
                obstruction_probabilities: null,
            };
            _log('  → mapped status :', mapped.status, '| category:', mapped.predicted_category, '| scale:', mapped.predicted_scale, '| obstruction:', mapped.predicted_obstruction);
            return mapped;
        }
        if (decision === 'REJECTED') {
            const mapped = {
                status: VALIDATION_STATUS.REJECTED,
                rejection_reason: 'Image classified as INVALID by automated validation (Exp 3.2).',
                auto_classification: safeAutoClass,
                predicted_category: null, // Rejected images don't get a category
                predicted_scale: null,
                scale_confidence: null,
                scale_probabilities: null,
                predicted_obstruction: null,
                obstruction_confidence: null,
                obstruction_probabilities: null,
            };
            _log('  → mapped status :', mapped.status, '| category: null (rejected)');
            return mapped;
        }
        // 'MANUAL_REVIEW' or any unexpected value → manual review
        const mapped = {
            status: VALIDATION_STATUS.MANUAL_REVIEW,
            rejection_reason: null,
            auto_classification: safeAutoClass,
            predicted_category: safeCategory,
            predicted_scale: null,
            scale_confidence: null,
            scale_probabilities: null,
            predicted_obstruction: null,
            obstruction_confidence: null,
            obstruction_probabilities: null,
        };
        _log('  → mapped status :', mapped.status, '| category:', mapped.predicted_category, '| scale:', mapped.predicted_scale, '| obstruction:', mapped.predicted_obstruction);
        return mapped;
    }

    // --- Fallback path: binary VALID/INVALID without explicit decision field ---
    _log('  (fallback path — no decision field)');
    if (safeAutoClass === 'VALID' || safeAutoClass === 'INVALID') {
        const numConfidence = (typeof confidence === 'number' && Number.isFinite(confidence)) ? confidence : 0;
        const probValid    = safeAutoClass === 'VALID' ? numConfidence : 1.0 - numConfidence;
        const inReviewZone = probValid >= REVIEW_LO && probValid <= REVIEW_HI;
        _log(`  probValid=${probValid.toFixed(4)}  inReviewZone=${inReviewZone}  threshold=${THRESHOLD}`);

        if (inReviewZone) {
            const mapped = {
                status: VALIDATION_STATUS.MANUAL_REVIEW,
                rejection_reason: null,
                auto_classification: safeAutoClass,
                predicted_category: safeCategory,
            };
            _log('  → mapped status :', mapped.status);
            return mapped;
        }
        if (probValid >= THRESHOLD) {
            const mapped = {
                status: VALIDATION_STATUS.APPROVED,
                rejection_reason: null,
                auto_classification: safeAutoClass,
                predicted_category: safeCategory,
            };
            _log('  → mapped status :', mapped.status);
            return mapped;
        }
        const mapped = {
            status: VALIDATION_STATUS.REJECTED,
            rejection_reason: 'Image classified as INVALID by automated validation.',
            auto_classification: safeAutoClass,
            predicted_category: null,
        };
        _log('  → mapped status :', mapped.status);
        return mapped;
    }

    // Unknown class
    _warn('  unknown predicted_class:', predicted_class, '— defaulting to MANUAL_REVIEW');
    return {
        status: VALIDATION_STATUS.MANUAL_REVIEW,
        rejection_reason: null,
        auto_classification: null,
        predicted_category: null,
    };
};
