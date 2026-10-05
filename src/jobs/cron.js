import cron from 'node-cron';
import { slaDetectionService } from '../modules/sweeper/services/sla-detection.service.js';

// Run SLA detection daily at 02:00 AM or as specified in environment
const cronSchedule = process.env.SLA_DETECTION_CRON || '0 2 * * *';

cron.schedule(cronSchedule, async () => {
  console.log('Running scheduled SLA detection...');
  try {
    const result = await slaDetectionService.detectAndFlagOutliers();
    console.log(`SLA detection completed: ${result.flaggedCount} reports flagged`);
  } catch (error) {
    console.error('SLA detection failed:', error);
    // Send alert to admin
  }
});
