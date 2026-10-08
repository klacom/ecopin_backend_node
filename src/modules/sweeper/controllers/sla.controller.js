import { slaDetectionService } from '../services/sla-detection.service.js';
import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

// In-memory state for SLA detection job
let isJobRunning = false;
let lastRunTimestamp = null;
let nextScheduledRunTimestamp = null; // Will be managed by the cron setup in Task 11

export async function triggerSlaDetection(req, res) {
  // Check role-based access control (dispatch officer)
  if (!['officer','admin'].includes(req.user?.role)) {
    return res.status(403).json({ error: 'Access denied: Dispatch Officer role required' });
  }

  // Mutex lock to prevent concurrent SLA detection runs
  if (isJobRunning) {
    return res.status(409).json({ error: 'SLA detection job is already running' });
  }

  isJobRunning = true;

  try {
    const result = await slaDetectionService.detectAndFlagOutliers();
    
    // Update last run timestamp
    lastRunTimestamp = new Date().toISOString();

    res.json({
      success: true,
      flaggedCount: result.flaggedCount,
      flaggedReports: result.flaggedReports
    });
  } catch (error) {
    console.error('Error during manual SLA detection trigger:', error);
    res.status(500).json({ error: 'Internal server error during SLA detection' });
  } finally {
    isJobRunning = false;
  }
}

export async function getSlaStatus(req, res) {
  // Check role-based access control
  if (!['officer','admin'].includes(req.user?.role)) {
    return res.status(403).json({ error: 'Access denied: Dispatch Officer role required' });
  }

  try {
    // Get current outlier count from reports table
    let query = supabase
      .from('reports')
      .select('*', { count: 'exact', head: true });
    query = process.env.REPORT_LIFECYCLE_ENABLED === 'true'
      ? query.eq('lifecycle_state', 'sla_breached')
      : query.eq('is_outlier', true).eq('status', 'unresolved');
    const { count, error } = await query;

    if (error) {
      throw error;
    }

    const {data:lastAudit,error:auditError}=await supabase.from('sweeper_audit_log').select('created_at,event_data').eq('event_type','LIFECYCLE_RUN_COMPLETED').order('created_at',{ascending:false}).limit(1).maybeSingle();
    if(auditError) throw auditError;
    res.json({
      isRunning: isJobRunning,
      lastRun: lastAudit?.created_at ?? lastRunTimestamp,
      nextScheduledRun: nextScheduledRunTimestamp, // This would normally be synced with the cron scheduler
      currentOutlierCount: count || 0
    });
  } catch (error) {
    console.error('Error fetching SLA status:', error);
    res.status(500).json({ error: 'Failed to fetch SLA detection status' });
  }
}

// Export a helper to update the next scheduled run from the cron job module
export function updateNextScheduledRun(timestamp) {
  nextScheduledRunTimestamp = timestamp;
}
