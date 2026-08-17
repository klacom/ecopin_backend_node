// Clustering module entry point
// Exports routes for app integration and services for external use

import clusterRoutes from './routes/cluster.routes.js';
export { clusterRoutes };

export { clusterReports, getClusters, getClusterById, updateClusterStatus } from './services/clustering.service.js';
export { CLUSTERING_CONFIG } from './config/clustering.config.js';
