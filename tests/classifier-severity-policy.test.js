import { jest } from '@jest/globals';

jest.unstable_mockModule('../src/config/index.js', () => ({
    CLASSIFIER_SERVICE_URL: '', USE_AWS_CLASSIFIER: false, AWS_CLASSIFIER_URL: '',
    VALIDATION_STATUS: { APPROVED: 'approved', REJECTED: 'rejected', MANUAL_REVIEW: 'manual_review' }
}));
jest.unstable_mockModule('sharp', () => ({ default: jest.fn() }));
const { mapClassifierToValidation } = await import('../src/services/classifierClient.service.js');

test.each(['APPROVED', 'MANUAL_REVIEW', 'REJECTED', 'unexpected'])(
    'ignores image-derived severity from older classifiers with decision %s', decision => {
        const mapped = mapClassifierToValidation({
            ok: true, predicted_class: 'VALID', decision, confidence: .99,
            predicted_category: 'waste', predicted_scale: 'large', scale_confidence: .99,
            scale_probabilities: { large: .99 }, predicted_obstruction: 'complete',
            obstruction_confidence: .99, obstruction_probabilities: { complete: .99 }
        });
        for (const field of ['predicted_scale', 'scale_confidence', 'scale_probabilities',
            'predicted_obstruction', 'obstruction_confidence', 'obstruction_probabilities']) {
            expect(mapped[field]).toBeNull();
        }
        expect(mapped.status).toBe(decision === 'APPROVED' ? 'approved' : decision === 'REJECTED' ? 'rejected' : 'manual_review');
        expect(mapped.predicted_category).toBe(decision === 'REJECTED' ? null : 'waste');
    }
);
