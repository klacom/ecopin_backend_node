import { Router } from 'express';
import { triggerClustering, getAllClusters, getCluster, updateCluster } from '../controllers/cluster.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// All cluster routes require authentication and officer/admin role
router.use(authenticate);
router.use(authorize(ROLE_GROUPS.DESK_OPS));

router.post('/trigger', triggerClustering);
router.get('/', getAllClusters);
router.get('/:id', getCluster);
router.patch('/:id/status', updateCluster);

export default router;
