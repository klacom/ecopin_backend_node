import { CLASSIFIER_SERVICE_URL, VALIDATION_STATUS } from '../config/index.js';

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
    if (!CLASSIFIER_SERVICE_URL) {
        _err('CLASSIFIER_SERVICE_URL is not configured — cannot classify image');
        throw new Error('CLASSIFIER_SERVICE_URL is not configured');
    }

    const endpoint = `${CLASSIFIER_SERVICE_URL}/classify`;
    const sizeKB   = (imageBuffer.byteLength / 1024).toFixed(1);

    // ── REQUEST ──────────────────────────────────────────────────────────────
    _log('──────────────────────────────────────────────');
    _log('→ REQUEST  POST', endpoint);
    _log('  file    :', originalName);
    _log('  mime    :', mimeType);
    _log('  size    :', `${sizeKB} KB  (${imageBuffer.byteLength} bytes)`);

    const t0         = Date.now();
    const controller = new AbortController();
    const timeoutMs  = 30000;
    const timeout    = setTimeout(() => controller.abort(), timeoutMs);

    try {
        const response = await fetch(endpoint, {
            method: 'POST',
            body: imageBuffer,
            headers: {
                'Content-Type': mimeType,
                'X-Filename': encodeURIComponent(originalName),
            },
            signal: controller.signal,
        });
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
        _log('  inference_ms       :', result.inference_ms ?? 'n/a');
        _log('──────────────────────────────────────────────');

        return {
            ok: true,
            predicted_class:    result.predicted_class,
            confidence:         result.confidence,
            probabilities:      result.probabilities,
            // Exp 3.2 fields
            decision:           result.decision,
            in_review_zone:     result.in_review_zone,
            // Zero-shot category (null when image is REJECTED)
            predicted_category: result.predicted_category ?? null,
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

    _log('mapClassifierToValidation:');
    _log('  predicted_class    :', predicted_class);
    _log('  confidence         :', confidence);
    _log('  decision           :', decision ?? '(none — using fallback path)');
    _log('  predicted_category :', classifierResult.predicted_category ?? '(null)');

    // --- Exp 3.2 path: use the decision field emitted by the inference service ---
    if (decision) {
        if (decision === 'APPROVED') {
            const mapped = {
                status: VALIDATION_STATUS.APPROVED,
                rejection_reason: null,
                auto_classification: predicted_class,
                predicted_category: classifierResult.predicted_category ?? null,
            };
            _log('  → mapped status :', mapped.status, '| category:', mapped.predicted_category);
            return mapped;
        }
        if (decision === 'REJECTED') {
            const mapped = {
                status: VALIDATION_STATUS.REJECTED,
                rejection_reason: 'Image classified as INVALID by automated validation (Exp 3.2).',
                auto_classification: predicted_class,
                predicted_category: null, // Rejected images don't get a category
            };
            _log('  → mapped status :', mapped.status, '| category: null (rejected)');
            return mapped;
        }
        // 'MANUAL_REVIEW' or any unexpected value → manual review
        const mapped = {
            status: VALIDATION_STATUS.MANUAL_REVIEW,
            rejection_reason: null,
            auto_classification: predicted_class,
            predicted_category: classifierResult.predicted_category ?? null,
        };
        _log('  → mapped status :', mapped.status, '| category:', mapped.predicted_category);
        return mapped;
    }

    // --- Fallback path: binary VALID/INVALID without explicit decision field ---
    _log('  (fallback path — no decision field)');
    if (predicted_class === 'VALID' || predicted_class === 'INVALID') {
        const probValid    = predicted_class === 'VALID' ? confidence : 1.0 - confidence;
        const inReviewZone = probValid >= REVIEW_LO && probValid <= REVIEW_HI;
        _log(`  probValid=${probValid.toFixed(4)}  inReviewZone=${inReviewZone}  threshold=${THRESHOLD}`);

        if (inReviewZone) {
            const mapped = {
                status: VALIDATION_STATUS.MANUAL_REVIEW,
                rejection_reason: null,
                auto_classification: predicted_class,
                predicted_category: classifierResult.predicted_category ?? null,
            };
            _log('  → mapped status :', mapped.status);
            return mapped;
        }
        if (probValid >= THRESHOLD) {
            const mapped = {
                status: VALIDATION_STATUS.APPROVED,
                rejection_reason: null,
                auto_classification: predicted_class,
                predicted_category: classifierResult.predicted_category ?? null,
            };
            _log('  → mapped status :', mapped.status);
            return mapped;
        }
        const mapped = {
            status: VALIDATION_STATUS.REJECTED,
            rejection_reason: 'Image classified as INVALID by automated validation.',
            auto_classification: predicted_class,
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
        auto_classification: predicted_class,
        predicted_category: null,
    };
};
