import { Router } from 'express';
import { triggerClustering, getAllClusters, getCluster, updateCluster } from '../controllers/cluster.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';

const router = Router();

// All cluster routes require authentication and LGU/admin role
router.use(authenticate);
router.use(authorize(['lgu', 'admin']));

router.post('/trigger', triggerClustering);
router.get('/', getAllClusters);
router.get('/:id', getCluster);
router.patch('/:id/status', updateCluster);

export default router;
