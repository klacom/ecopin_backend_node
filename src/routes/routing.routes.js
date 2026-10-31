import {Router} from 'express';
import {authenticate,checkUserSuspension,authorize} from '../middleware/auth.middleware.js';
import {ROLE_GROUPS} from '../constants/roles.js';
import {getDrivingDirections} from '../controllers/routing.controller.js';
const router=Router();
router.get('/directions',authenticate,checkUserSuspension,authorize(ROLE_GROUPS.FIELD_OPS),getDrivingDirections);
export default router;
