import { jest } from '@jest/globals';
import { calculateSeverity } from '../src/services/severity.service.js';
import { SEVERITY_CONFIG } from '../src/config/severity.config.js';

// Mock supabaseAdmin
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabaseAdmin: {
    rpc: jest.fn().mockResolvedValue({ data: 1, error: null })
  }
}));

describe('Environmental Severity Metric Service', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('should calculate minimum severity when inputs are lowest', async () => {
        const reportData = {
            scale_level: 'small', // 33 * 0.25 = 8.25
            issue_type: 'waste',  // 40 * 0.25 = 10
            obstruction_level: 'none', // 0
            on_private_property: true, // 20 * 0.15 = 3
            location: null // 20 * 0.15 = 3
        };
        // 8.25 + 10 + 0 + 3 + 3 = 24.25 (Rounded = 24) -> Low

        const result = await calculateSeverity(reportData);
        
        expect(result.severityScore).toBe(24);
        expect(result.severityLevel).toBe('Low');
    });

    test('should calculate maximum severity when inputs are highest (except persistence due to mock)', async () => {
        const reportData = {
            scale_level: 'large', // 100 * 0.25 = 25
            issue_type: 'flooding', // 80 * 0.25 = 20
            obstruction_level: 'complete', // 100 * 0.20 = 20
            on_private_property: false, // 50 * 0.15 = 7.5
            location: 'POINT(121.05 14.55)' // persistence mock returns 1 -> 20 * 0.15 = 3
        };
        // 25 + 20 + 20 + 3 + 7.5 = 75.5 (Rounded = 76) -> High

        const result = await calculateSeverity(reportData);
        
        expect(result.severityScore).toBe(76);
        expect(result.severityLevel).toBe('High');
    });

    test('should handle missing inputs gracefully using fallbacks', async () => {
        const result = await calculateSeverity({});
        
        // Defaults: scale(50), hazard(40), obstruction(0), persistence(20), loc(50)
        // 50*0.25(12.5) + 40*0.25(10) + 0 + 20*0.15(3) + 50*0.15(7.5) = 33 -> Low
        expect(result.severityScore).toBe(33);
        expect(result.severityLevel).toBe('Low');
        expect(result.severityFactors.scale).toBe(50);
        expect(result.severityFactors.obstruction).toBe(0);
    });

    test('should map different severity levels correctly', async () => {
        const reportDataHigh = {
            scale_level: 'medium', // 66 * 0.25 = 16.5
            issue_type: 'pollution', // 70 * 0.25 = 17.5
            obstruction_level: 'partial', // 50 * 0.20 = 10
            on_private_property: false, // 50 * 0.15 = 7.5
            location: null // 20 * 0.15 = 3 (Total = 54.5 -> Moderate)
        };
        
        const resultModerate = await calculateSeverity(reportDataHigh);
        expect(resultModerate.severityLevel).toBe('Moderate');
        
        const reportDataHigh2 = {
            ...reportDataHigh,
            obstruction_level: 'complete' // 100 * 0.2 = 20
        };
        // 16.5 + 17.5 + 20 + 7.5 + 3 = 64.5 (Rounded = 65)
        const resultHigh = await calculateSeverity(reportDataHigh2);
        expect(resultHigh.severityLevel).toBe('High');
        expect(resultHigh.severityScore).toBe(65);
    });

    test('should parse geojson location and call persistence correctly', async () => {
        const { supabaseAdmin } = await import('../src/config/supabase.config.js');

        const reportData = {
            location: { type: 'Point', coordinates: [121.05, 14.55] }
        };

        const result = await calculateSeverity(reportData);

        expect(supabaseAdmin.rpc).toHaveBeenCalledWith('count_recent_nearby_reports', {
            p_lon: 121.05,
            p_lat: 14.55,
            p_radius_meters: 50,
            p_days: 30
        });
        
        // 1 report -> persistence score is 20.
        expect(result.severityFactors.persistence).toBe(20);
    });
});
