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

export const calculateRA9003Category = (predictedClass, title = '', description = '') => {
    const combinedText = `${title} ${description}`.toLowerCase();
    
    // Map to RA 9003 categories: solid/bulky/special/na
    // flooding/pollution → na (outside RA 9003 solid waste scope)
    if (predictedClass === 'flooding' || predictedClass === 'pollution') {
        return 'na';
    }
    
    // Special waste heuristics (batteries, chemicals, hazardous materials)
    const specialKeywords = ['battery', 'batteries', 'chemical', 'oil', 'toxic', 'hazardous', 'medical', 'e-waste', 'electronic'];
    if (specialKeywords.some(keyword => combinedText.includes(keyword))) {
        return 'special';
    }
    
    // Bulky waste heuristics (large items, furniture, appliances)
    const bulkyKeywords = ['furniture', 'sofa', 'couch', 'mattress', 'appliance', 'refrigerator', 'fridge', 'washing machine', 'tv', 'television'];
    if (bulkyKeywords.some(keyword => combinedText.includes(keyword))) {
        return 'bulky';
    }
    
    // Default: waste → solid
    if (predictedClass === 'waste') {
        return 'solid';
    }
    
    // Fallback for non_environmental or other classes
    return 'na';
};

export const calculateSeverityScore = (predictedClass, confidence, onPrivateProperty = false) => {
    let severity = 1;
    
    // Base score from class
    if (predictedClass === 'waste' || predictedClass === 'pollution') {
        severity = 2;
    } else if (predictedClass === 'flooding') {
        severity = 1;
    } else if (predictedClass === 'non_environmental') {
        severity = 1;
    }
    
    // Confidence boost: higher confidence = higher severity
    if (confidence > 0.85) {
        severity = Math.min(severity + 1, 3);
    } else if (confidence > 0.70) {
        // Keep base severity for medium confidence
    } else {
        // Low confidence reduces severity
        severity = Math.max(severity - 1, 1);
    }
    
    // Location modifier: public property slightly higher severity
    if (!onPrivateProperty && severity < 3) {
        severity = severity + 1;
    }
    
    // Ensure within 1-3 range
    return Math.max(1, Math.min(3, severity));
};

export const calculateUrgencyScore = (predictedClass, onPrivateProperty = false, description = '') => {
    let urgency = 1;
    const descriptionLower = description.toLowerCase();
    
    // Base score from class
    if (predictedClass === 'pollution') {
        urgency = 2;
    } else if (predictedClass === 'waste') {
        urgency = 1;
    } else if (predictedClass === 'flooding') {
        urgency = 2;
    } else if (predictedClass === 'non_environmental') {
        urgency = 1;
    }
    
    // Property modifier: public property = higher urgency
    if (!onPrivateProperty) {
        urgency = Math.min(urgency + 1, 3);
    } else {
        urgency = Math.max(urgency - 1, 1);
    }
    
    // Description keywords: hazardous/emergency situations increase urgency
    const urgencyKeywords = ['hazardous', 'toxic', 'emergency', 'dangerous', 'immediate', 'urgent', 'spilling', 'leaking'];
    if (urgencyKeywords.some(keyword => descriptionLower.includes(keyword))) {
        urgency = Math.min(urgency + 1, 3);
    }
    
    // Ensure within 1-3 range
    return Math.max(1, Math.min(3, urgency));
};
