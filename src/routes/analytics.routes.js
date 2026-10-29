import {Router} from 'express';
import {authenticate,authorize} from '../middleware/auth.middleware.js';
import {ROLE_GROUPS} from '../constants/roles.js';
import {getBarangayAnalytics} from '../controllers/barangay-analytics.controller.js';
const router=Router();
router.get('/barangay',authenticate,authorize(ROLE_GROUPS.STATS_VIEWERS),getBarangayAnalytics);
export default router;
