// Spatial Forecast Configuration

export const SPATIAL_FORECAST_CONFIG = {
  // Python service URL
  serviceUrl: process.env.USE_AWS_SPATIAL_FORECAST === 'true' 
    ? process.env.AWS_SPATIAL_FORECAST_SERVICE_URL 
    : (process.env.LOCAL_SPATIAL_FORECAST_SERVICE_URL || 'http://127.0.0.1:8002'),

  // Time horizons in days
  timeHorizons: {
    '7d': 7,
    '30d': 30,
    '90d': 90
  },

  // Hotspot thresholds
  riskScore: {
    high: 0.7,
    medium: 0.4
  },

  // Scheduling configuration
  scheduling: {
    daily: {
      cron: '0 6 * * *', // 6 AM daily
      enabled: true
    },
    weekly: {
      cron: '0 6 * * 1', // 6 AM every Monday
      enabled: true
    },
    monthly: {
      cron: '0 6 1 * *', // 6 AM on 1st of month
      enabled: true
    }
  },

  // Cache settings
  cache: {
    enabled: true,
    ttl: 3600000 // 1 hour in milliseconds
  },

  // Request timeout
  timeout: 60000 // 60 seconds
};

// Legacy labels now select forward windows: daily/weekly -> +7d, monthly -> +30d.
export const normalizeHorizon = value => {
  const aliases = { daily: '7d', weekly: '7d', monthly: '30d' };
  if (typeof value !== 'string') throw Object.assign(new Error('Horizon must be 7d, 30d or 90d'), { statusCode: 400 });
  const horizon = Object.hasOwn(aliases, value) ? aliases[value] : value;
  if (!Object.hasOwn(SPATIAL_FORECAST_CONFIG.timeHorizons, horizon)) {
    throw Object.assign(new Error('Horizon must be 7d, 30d or 90d'), { statusCode: 400 });
  }
  return horizon;
};
