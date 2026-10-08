import express from 'express';
import { 
  getConfig, 
  updateSlaThresholdConfig, 
  updateShiftDurationConfig, 
  updateWorkTimeConfig 
} from '../controllers/configuration.controller.js';
import { getAuditLogs } from '../controllers/audit.controller.js';

const router = express.Router();

import { authenticate, authorize } from '../../../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../../../constants/roles.js';
router.use(authenticate, authorize(ROLE_GROUPS.DESK_OPS));

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
import { generateSweeperRoutes } from '../../optimization/controllers/optimization.controller.js';

router.post('/optimize', authenticate, generateSweeperRoutes);

// Sweeper Analytics Routes
import { getMetrics, exportMetrics } from '../controllers/analytics.controller.js';

router.get('/analytics/metrics', authenticate, getMetrics);
router.get('/analytics/export', authenticate, exportMetrics);

export default router;
