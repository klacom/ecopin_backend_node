import { supabaseAdmin as supabase } from '../config/supabase.config.js';
import { SEVERITY_CONFIG } from '../config/severity.config.js';

/**
 * Maps a calculated score to a severity level string.
 */
function getSeverityLevel(score) {
    for (const level of SEVERITY_CONFIG.levels) {
        if (score <= level.max) {
            return level.name;
        }
    }
    return 'Critical'; // Fallback
}

/**
 * Calculates the persistence score based on nearby recent reports.
 */
async function calculatePersistenceScore(longitude, latitude) {
    try {
        const { data, error } = await supabase.rpc('count_recent_nearby_reports', {
            p_lon: longitude,
            p_lat: latitude,
            p_radius_meters: SEVERITY_CONFIG.persistence.radiusMeters,
            p_days: SEVERITY_CONFIG.persistence.timeWindowDays
        });

        if (error) {
            console.error('[SeverityService] Error calling count_recent_nearby_reports RPC:', error);
            return SEVERITY_CONFIG.persistence.scoreMap[1]; // Fallback to baseline (1 report = self)
        }

        const count = data || 1; // Assuming self is included
        
        // Map the count to a persistence score (cap at maxScore)
        if (SEVERITY_CONFIG.persistence.scoreMap[count] !== undefined) {
            return SEVERITY_CONFIG.persistence.scoreMap[count];
        } else {
            return SEVERITY_CONFIG.persistence.maxScore;
        }
    } catch (err) {
        console.error('[SeverityService] Exception calculating persistence:', err);
        return SEVERITY_CONFIG.persistence.scoreMap[1]; // Safe fallback
    }
}

/**
 * Main function to calculate and structure the Environmental Severity Metric.
 * @param {Object} reportData - the current report record from db
 * @returns {Object} { severityScore, severityLevel, severityFactors }
 */
export const calculateSeverity = async (reportData) => {
    try {
        // 1. Scale
        const scaleRaw = (reportData.scale_level || '').toLowerCase();
        const scaleScore = SEVERITY_CONFIG.scaleValues[scaleRaw] ?? SEVERITY_CONFIG.scaleValues.default;

        // 2. Hazard
        const issueType = (reportData.issue_type || '').toLowerCase();
        const hazardScore = SEVERITY_CONFIG.hazardBaselines[issueType] ?? SEVERITY_CONFIG.hazardBaselines.default;

        // 3. Obstruction
        const obstructionRaw = (reportData.obstruction_level || '').toLowerCase();
        const obstructionScore = SEVERITY_CONFIG.obstructionValues[obstructionRaw] ?? SEVERITY_CONFIG.obstructionValues.default;

        // 4. Persistence
        let persistenceScore = SEVERITY_CONFIG.persistence.scoreMap[1]; // Base fallback
        if (reportData.location) {
            // Parse PostGIS point string if it's stored as 'POINT(lon lat)'
            let lon = 0, lat = 0;
            if (typeof reportData.location === 'string' && reportData.location.startsWith('POINT')) {
                const match = reportData.location.match(/POINT\(([^ ]+) ([^)]+)\)/);
                if (match) {
                    lon = parseFloat(match[1]);
                    lat = parseFloat(match[2]);
                    persistenceScore = await calculatePersistenceScore(lon, lat);
                }
            } else if (reportData.location.coordinates) {
                // GeoJSON format fallback
                lon = reportData.location.coordinates[0];
                lat = reportData.location.coordinates[1];
                persistenceScore = await calculatePersistenceScore(lon, lat);
            }
        }

        // 5. Location Sensitivity
        const locationSensitivityScore = reportData.on_private_property 
            ? SEVERITY_CONFIG.locationSensitivity.privateProperty 
            : SEVERITY_CONFIG.locationSensitivity.publicSpace;

        // Calculate weighted score
        const weightedScore = 
            (scaleScore * SEVERITY_CONFIG.weights.scale) +
            (hazardScore * SEVERITY_CONFIG.weights.hazard) +
            (obstructionScore * SEVERITY_CONFIG.weights.obstruction) +
            (persistenceScore * SEVERITY_CONFIG.weights.persistence) +
            (locationSensitivityScore * SEVERITY_CONFIG.weights.locationSensitivity);

        const finalScore = Math.min(Math.max(Math.round(weightedScore), 0), 100);
        const levelName = getSeverityLevel(finalScore);

        const factors = {
            scale: scaleScore,
            hazard: hazardScore,
            obstruction: obstructionScore,
            persistence: persistenceScore,
            locationSensitivity: locationSensitivityScore,
            explanation: `${levelName} severity due primarily to ` + getExplanation(scaleScore, hazardScore, obstructionScore, persistenceScore, locationSensitivityScore)
        };

        return {
            severityScore: finalScore,
            severityLevel: levelName,
            severityFactors: factors
        };
    } catch (error) {
        console.error('[SeverityService] Error calculating severity:', error);
        // Ensure deterministic fallback if everything fails
        return {
            severityScore: 50,
            severityLevel: 'Moderate',
            severityFactors: {
                error: 'Failed to compute full severity. Using fallback values.',
                scale: 50, hazard: 50, obstruction: 0, persistence: 20, locationSensitivity: 50
            }
        };
    }
};

function getExplanation(scale, hazard, obstruction, persistence, locationSens) {
    // A quick heuristic to generate a human-readable explanation
    const factorsMap = {
        'significant scale': scale * SEVERITY_CONFIG.weights.scale,
        'elevated hazard type': hazard * SEVERITY_CONFIG.weights.hazard,
        'significant obstruction': obstruction * SEVERITY_CONFIG.weights.obstruction,
        'high persistence of reports in the area': persistence * SEVERITY_CONFIG.weights.persistence,
        'elevated location sensitivity': locationSens * SEVERITY_CONFIG.weights.locationSensitivity
    };
    
    // Sort factors by highest weighted contribution
    const sorted = Object.entries(factorsMap).sort((a, b) => b[1] - a[1]);
    
    // Take the top 2 reasons
    const topReasons = sorted.slice(0, 2).map(r => r[0]);
    return topReasons.join(' and ') + '.';
}
