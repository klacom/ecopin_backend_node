import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { logSlaBreachDetection } from './audit-log.service.js';

class SlaDetectionService {
  /**
   * Execute SLA detection and flag aged reports
   * @returns {Promise<{flaggedCount: number, flaggedReports: Array}>}
   */
  async detectAndFlagOutliers() {
    // Execute the stored procedure
    const { data: flaggedReports, error } = await supabase.rpc('detect_sla_outliers');

    if (error) {
      console.error('Error executing detect_sla_outliers procedure:', error);
      throw new Error(`SLA detection failed: ${error.message}`);
    }

    const processedReports = [];

    // Log audit event for each flagged report
    if (flaggedReports && flaggedReports.length > 0) {
      for (const report of flaggedReports) {
        try {
          await logSlaBreachDetection(report.report_id, report.breach_duration);
          
          processedReports.push({
            id: report.report_id,
            breachDuration: report.breach_duration,
            timestamp: new Date(report.flagged_at)
          });
        } catch (logError) {
          console.error(`Failed to log audit event for report ${report.report_id}:`, logError);
          // Continuing execution despite audit log failure to return correct results
        }
      }
    }

    return {
      flaggedCount: processedReports.length,
      flaggedReports: processedReports
    };
  }

  /**
   * Get current SLA threshold from configuration
   * @returns {Promise<number>} - Threshold in hours
   */
  async getSlaThreshold() {
    const { data, error } = await supabase
      .from('sweeper_configuration')
      .select('parameter_value')
      .eq('parameter_name', 'sla_threshold_hours')
      .single();
      
    if (error || !data) {
      return 48; // Default to 48 hours if not found
    }
    
    // In SQL the parameter_value is just a string '48' based on the design doc
    return Number(data.parameter_value);
  }
}

export const slaDetectionService = new SlaDetectionService();
