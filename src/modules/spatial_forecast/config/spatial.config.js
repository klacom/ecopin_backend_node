// Spatial Forecast Configuration

export const SPATIAL_FORECAST_CONFIG = {
  // Python service URL
  serviceUrl: process.env.SPATIAL_FORECAST_SERVICE_URL || 'http://127.0.0.1:8002',

  // Time horizons in days
  timeHorizons: {
    daily: 1,
    weekly: 7,
    monthly: 30
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
