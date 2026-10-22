import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { getSlaThreshold } from './configuration.service.js';

class SlaDetectionService {
  /**
   * Execute SLA detection and flag aged reports
   * @returns {Promise<{flaggedCount: number, flaggedReports: Array}>}
   */
  async detectAndFlagOutliers() {
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

  /**
   * Get current SLA threshold from configuration
   * @returns {Promise<number>} - Threshold in hours
   */
  async getSlaThreshold() {
    return getSlaThreshold();
  }
}

export const slaDetectionService = new SlaDetectionService();
