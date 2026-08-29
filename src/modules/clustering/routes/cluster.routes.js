import { Router } from 'express';
import { triggerClustering, getAllClusters, getCluster, updateCluster } from '../controllers/cluster.controller.js';
import { authenticate, authorize } from '../../../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../../../constants/roles.js';

const router = Router();

// All cluster routes require authentication
router.use(authenticate);

// Trigger clustering requires desk ops (admin/officer only)
router.post('/trigger', authorize(ROLE_GROUPS.DESK_OPS), triggerClustering);

// Viewing clusters and updating status requires field ops (includes field crew)
router.use(authorize(ROLE_GROUPS.FIELD_OPS));
router.get('/', getAllClusters);
router.get('/:id', getCluster);
router.patch('/:id/status', updateCluster);

export default router;
