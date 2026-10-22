import cron from 'node-cron';
import { slaDetectionService } from '../modules/sweeper/services/sla-detection.service.js';

let scheduledTask = null;
let running = false;

export function startSlaSchedule({ env = process.env, scheduler = cron, service = slaDetectionService, logger = console } = {}) {
  if (env.REPORT_LIFECYCLE_ENABLED !== 'true') return null;
  if (scheduledTask) return scheduledTask;
  const schedule = env.SLA_DETECTION_CRON || '0 * * * *';
  const timezone = env.SLA_DETECTION_TIMEZONE || 'Asia/Manila';
  if (!scheduler.validate(schedule)) throw new Error('Invalid SLA_DETECTION_CRON');
  scheduledTask = scheduler.schedule(schedule, async () => {
    if (running) return;
    running = true;
    const startedAt = new Date().toISOString();
    try {
      const result = await service.detectAndFlagOutliers();
      logger.info('[ReportLifecycle] completed', { startedAt, completedAt: new Date().toISOString(), ...result });
    } catch (error) {
      logger.error('[ReportLifecycle] failed', { startedAt, error: error.message });
    } finally {
      running = false;
    }
  }, { timezone });
  logger.info('[ReportLifecycle] registered', { schedule, timezone });
  return scheduledTask;
}

export function stopSlaSchedule() {
  scheduledTask?.stop();
  scheduledTask = null;
}
