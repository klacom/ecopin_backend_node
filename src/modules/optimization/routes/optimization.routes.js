import { Router } from 'express';
import { authenticate, authorize } from '../../../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../../../constants/roles.js';
import * as ctrl from '../controllers/optimization.controller.js';

const router = Router();

// All optimization routes require authentication
router.use(authenticate);

// Officer/Admin can run and manage optimization
router.post('/run', authorize(ROLE_GROUPS.DESK_OPS), ctrl.runOptimization);
router.get('/runs', authorize(ROLE_GROUPS.DESK_OPS), ctrl.getOptimizationRuns);
router.get('/runs/:id', authorize(ROLE_GROUPS.DESK_OPS), ctrl.getOptimizationRunById);
router.post('/runs/:id/approve', authorize(ROLE_GROUPS.DESK_OPS), ctrl.approveOptimization);
router.post('/runs/:id/discard', authorize(ROLE_GROUPS.DESK_OPS), ctrl.discardOptimization);

// Phase 2: Work Queue Endpoints
router.post('/queue/prioritize', authorize(ROLE_GROUPS.DESK_OPS), ctrl.prioritizeQueue);
router.get('/queue', authorize(ROLE_GROUPS.DESK_OPS), ctrl.fetchWorkQueue);
router.post('/dispatch', authorize(ROLE_GROUPS.DESK_OPS), ctrl.explicitDispatch);

// Phase 3: Capacity-Aware Planning Endpoints
router.post('/plan/generate', authorize(ROLE_GROUPS.DESK_OPS), ctrl.generatePlan);
router.get('/plan/:id/items', authorize(ROLE_GROUPS.DESK_OPS), ctrl.getPlanItems);
router.post('/plan/:id/commit', authorize(ROLE_GROUPS.DESK_OPS), ctrl.commitPlan);

// Route viewing — accessible to field ops (officers + field crew)
router.get('/routes/active', authorize(ROLE_GROUPS.FIELD_OPS), ctrl.getActiveRoutes);
router.get('/routes/:routeId', authorize(ROLE_GROUPS.FIELD_OPS), ctrl.getRouteById);
router.get('/routes/:routeId/waypoints', authorize(ROLE_GROUPS.FIELD_OPS), ctrl.getRouteWaypoints);

// Field crews
router.get('/crews', authorize(ROLE_GROUPS.FIELD_OPS), ctrl.getFieldCrews);
router.post('/tasks/:id/complete', authorize(ROLE_GROUPS.FIELD_OPS), ctrl.completeTask);
router.put('/crews/:id', authorize(ROLE_GROUPS.ADMIN_ONLY), ctrl.updateFieldCrew);

// Admin settings
router.get('/settings', authorize(ROLE_GROUPS.ADMIN_ONLY), ctrl.getOptimizationSettings);
router.put('/settings', authorize(ROLE_GROUPS.ADMIN_ONLY), ctrl.updateOptimizationSettings);

export { router as optimizationRoutes };
