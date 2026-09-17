export const SEVERITY_CONFIG = {
    // Weights for each factor (must sum to 1.0 or 100%)
    weights: {
        scale: 0.25,
        hazard: 0.25,
        obstruction: 0.20,
        persistence: 0.15,
        locationSensitivity: 0.15
    },

    // 0-100 values for structured scale inputs
    scaleValues: {
        small: 33,
        medium: 66,
        large: 100,
        // Fallback if not provided
        default: 50
    },

    // 0-100 values for structured obstruction inputs
    obstructionValues: {
        none: 0,
        partial: 50,
        complete: 100,
        // Fallback if not provided
        default: 0
    },

    // Baseline hazard scores (0-100) mapped from issue_type / AI predicted category
    hazardBaselines: {
        waste: 40,
        flooding: 80,
        pollution: 70,
        infrastructure: 60,
        // Add more categories if your system defines them
        default: 40
    },

    // Persistence mapping based on number of nearby reports in time window
    persistence: {
        radiusMeters: 50,
        timeWindowDays: 30,
        // Values mapped by count of reports
        scoreMap: {
            0: 20, // Should be 1 (current report) minimally, but just in case
            1: 20,
            2: 40,
            3: 60,
            4: 80
        },
        maxScore: 100
    },

    locationSensitivity: {
        // Safe fallbacks without POI data
        privateProperty: 20, // Less public impact
        publicSpace: 50      // Neutral baseline
    },

    // Final score to Severity Level mapping
    levels: [
        { max: 19, name: 'Minimal' },
        { max: 39, name: 'Low' },
        { max: 59, name: 'Moderate' },
        { max: 79, name: 'High' },
        { max: 100, name: 'Critical' }
    ]
};
