// Spatial Forecast module entry point
// Exports routes for app integration and services for external use

import spatialRoutes from './routes/spatial.routes.js';
export { spatialRoutes };

export { 
  generateForecast, 
  getPredictions, 
  getCurrentPredictions,
  getAccuracyMetrics 
} from './services/spatialClient.service.js';

export { 
  scheduleDailyForecast,
  scheduleWeeklyForecast,
  scheduleMonthlyForecast 
} from './services/forecastScheduler.service.js';

export { SPATIAL_FORECAST_CONFIG } from './config/spatial.config.js';
