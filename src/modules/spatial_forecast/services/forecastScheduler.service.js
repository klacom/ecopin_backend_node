// Forecast Scheduler Service
// Handles periodic prediction generation using node-cron

import cron from 'node-cron';
import { generateForecast } from './spatialClient.service.js';
import { SPATIAL_FORECAST_CONFIG } from '../config/spatial.config.js';

const scheduledTasks = new Map();

/**
 * Refresh +7d, +30d, and +90d forecasts daily so all horizons stay current
 */
export const scheduleDailyForecast = () => {
  if (!SPATIAL_FORECAST_CONFIG.scheduling.daily.enabled) {
    console.log('[ForecastScheduler] Daily scheduling disabled');
    return;
  }
  
  const task = cron.schedule(
    SPATIAL_FORECAST_CONFIG.scheduling.daily.cron,
    async () => {
      console.log('[ForecastScheduler] Running daily forecast generation across all horizons');
      for (const horizon of ['7d', '30d', '90d']) {
        try {
          await generateForecast(horizon);
          console.log(`[ForecastScheduler] Daily ${horizon} forecast completed successfully`);
        } catch (error) {
          console.error(`[ForecastScheduler] Daily ${horizon} forecast failed:`, error);
        }
      }
    },
    { timezone: 'Asia/Manila' }
  );
  
  scheduledTasks.set('daily', task);
  console.log(`[ForecastScheduler] Daily forecast scheduled: ${SPATIAL_FORECAST_CONFIG.scheduling.daily.cron}`);
};

/**
 * Refresh +30-day forecasts weekly
 */
export const scheduleWeeklyForecast = () => {
  if (!SPATIAL_FORECAST_CONFIG.scheduling.weekly.enabled) {
    console.log('[ForecastScheduler] Weekly scheduling disabled');
    return;
  }
  
  const task = cron.schedule(
    SPATIAL_FORECAST_CONFIG.scheduling.weekly.cron,
    async () => {
      console.log('[ForecastScheduler] Running weekly forecast generation');
      try {
        await generateForecast('30d');
        console.log('[ForecastScheduler] Weekly forecast completed successfully');
      } catch (error) {
        console.error('[ForecastScheduler] Weekly forecast failed:', error);
      }
    },
    { timezone: 'Asia/Manila' }
  );
  
  scheduledTasks.set('weekly', task);
  console.log(`[ForecastScheduler] Weekly forecast scheduled: ${SPATIAL_FORECAST_CONFIG.scheduling.weekly.cron}`);
};

/**
 * Refresh +90-day forecasts monthly
 */
export const scheduleMonthlyForecast = () => {
  if (!SPATIAL_FORECAST_CONFIG.scheduling.monthly.enabled) {
    console.log('[ForecastScheduler] Monthly scheduling disabled');
    return;
  }
  
  const task = cron.schedule(
    SPATIAL_FORECAST_CONFIG.scheduling.monthly.cron,
    async () => {
      console.log('[ForecastScheduler] Running monthly forecast generation');
      try {
        await generateForecast('90d');
        console.log('[ForecastScheduler] Monthly forecast completed successfully');
      } catch (error) {
        console.error('[ForecastScheduler] Monthly forecast failed:', error);
      }
    },
    { timezone: 'Asia/Manila' }
  );
  
  scheduledTasks.set('monthly', task);
  console.log(`[ForecastScheduler] Monthly forecast scheduled: ${SPATIAL_FORECAST_CONFIG.scheduling.monthly.cron}`);
};

/**
 * Start all scheduled tasks
 */
export const startAllSchedules = () => {
  console.log('[ForecastScheduler] Starting all forecast schedules');
  scheduleDailyForecast();
  scheduleWeeklyForecast();
  scheduleMonthlyForecast();
};

/**
 * Stop a specific scheduled task
 */
export const stopSchedule = (horizon) => {
  const task = scheduledTasks.get(horizon);
  if (task) {
    task.stop();
    scheduledTasks.delete(horizon);
    console.log(`[ForecastScheduler] Stopped ${horizon} forecast schedule`);
  }
};

/**
 * Stop all scheduled tasks
 */
export const stopAllSchedules = () => {
  console.log('[ForecastScheduler] Stopping all forecast schedules');
  for (const [horizon, task] of scheduledTasks) {
    task.stop();
  }
  scheduledTasks.clear();
};
