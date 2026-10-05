import express from 'express';
import { 
  getConfig, 
  updateSlaThresholdConfig, 
  updateShiftDurationConfig, 
  updateWorkTimeConfig 
} from '../controllers/configuration.controller.js';
import { getAuditLogs } from '../controllers/audit.controller.js';

const router = express.Router();

// Mock authentication/authorization middleware for these routes
// In a real application, replace this with your actual auth middleware
const authenticate = (req, res, next) => {
  // Assume req.user is set by prior middleware
  next();
};

// Configuration Routes
router.get('/config', authenticate, getConfig);
router.put('/config/sla-threshold', authenticate, updateSlaThresholdConfig);
router.put('/config/shift-duration', authenticate, updateShiftDurationConfig);
router.put('/config/work-time', authenticate, updateWorkTimeConfig);

// Audit Log Routes
router.get('/audit', authenticate, getAuditLogs);

// SLA Detection Routes
import { triggerSlaDetection, getSlaStatus } from '../controllers/sla.controller.js';

router.post('/sla/trigger', authenticate, triggerSlaDetection);
router.get('/sla/status', authenticate, getSlaStatus);

// Sweeper Optimization Routes
import { generateSweeperRoutes, getUnassignedOutlierClusters } from '../../optimization/controllers/optimization.controller.js';

router.post('/optimize', authenticate, generateSweeperRoutes);
router.get('/clusters', authenticate, getUnassignedOutlierClusters);

// Sweeper Analytics Routes
import { getMetrics, exportMetrics } from '../controllers/analytics.controller.js';

router.get('/analytics/metrics', authenticate, getMetrics);
router.get('/analytics/export', authenticate, exportMetrics);

export default router;
