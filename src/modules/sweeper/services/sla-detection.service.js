import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { logSlaBreachDetection } from './audit-log.service.js';
import { getSlaThreshold } from './configuration.service.js';

class SlaDetectionService {
  /**
   * Execute SLA detection and flag aged reports
   * @returns {Promise<{flaggedCount: number, flaggedReports: Array}>}
   */
  async detectAndFlagOutliers() {
    if (process.env.REPORT_LIFECYCLE_ENABLED === 'true') {
      const { data, error } = await supabase.rpc('advance_report_lifecycle');
      if (error) throw new Error(`Lifecycle advancement failed: ${error.message}`);
      return {
        flaggedCount: data.newlyBreached.length,
        flaggedReports: data.newlyBreached,
        changedCount: data.changedCount,
        skipped: data.skipped,
        auditFailureCount: 0
      };
    }
    // Execute the stored procedure
    const { data: flaggedReports, error } = await supabase.rpc('detect_sla_outliers');

    if (error) {
      console.error('Error executing detect_sla_outliers procedure:', error);
      throw new Error(`SLA detection failed: ${error.message}`);
    }

    const processedReports = [];
    let auditFailureCount = 0;

    // Log audit event for each flagged report
    if (flaggedReports && flaggedReports.length > 0) {
      for (const report of flaggedReports) {
        processedReports.push({ id: report.report_id, breachDuration: report.breach_duration, timestamp: new Date(report.flagged_at) });
        try {
          await logSlaBreachDetection(report.report_id, report.breach_duration);
        } catch (logError) {
          auditFailureCount++;
          console.error(`Failed to log audit event for report ${report.report_id}:`, logError);
          // Continuing execution despite audit log failure to return correct results
        }
      }
    }

    return {
      flaggedCount: processedReports.length,
      flaggedReports: processedReports,
      auditFailureCount
    };
  }

  /**
   * Get current SLA threshold from configuration
   * @returns {Promise<number>} - Threshold in hours
   */
  async getSlaThreshold() {
    return getSlaThreshold();
  }
}

export const slaDetectionService = new SlaDetectionService();
