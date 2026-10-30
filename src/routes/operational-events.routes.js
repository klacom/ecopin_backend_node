import {getLiveOperations} from '../controllers/live-operations.controller.js';
import {Router} from 'express';
import {authenticate,checkUserSuspension,authorize} from '../middleware/auth.middleware.js';
import {ROLE_GROUPS} from '../constants/roles.js';
import {getOperationalEvents} from '../controllers/operational-events.controller.js';
const router=Router();
router.get('/live',authenticate,checkUserSuspension,authorize(ROLE_GROUPS.DESK_OPS),getLiveOperations);
router.get('/',authenticate,checkUserSuspension,authorize(ROLE_GROUPS.DESK_OPS),getOperationalEvents);
export default router;
