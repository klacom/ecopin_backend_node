// Clustering module configuration
export const CLUSTERING_CONFIG = {
  // DBSCAN algorithm parameters
  dbscan: {
    eps: 50,           // Maximum distance between points (in meters)
    minpoints: 2,      // Minimum points required to form a cluster
  },
  
  // Severity thresholds based on report count
  severity: {
    high: 5,           // 5+ reports = high severity
    medium: 3,         // 3-4 reports = medium severity
    low: 2,            // 2 reports = low severity
  },
  
  // Scheduling configuration (for future implementation)
  scheduling: {
    enabled: false,    // Enable automatic scheduled clustering
    interval: '1h',    // Run every hour
    cronExpression: '0 * * * *', // Cron expression for hourly runs
  },
  
  // Report filtering
  filter: {
    status: 'unresolved', // Only cluster unresolved reports
    maxAge: null,        // Optional: max age of reports to cluster (e.g., '7d')
  }
};
