import { Router } from 'express';
import {
    getUnresolvedConflicts,
    resolveConflict
} from '../controllers/conflict.controller.js';
import { authenticate, checkUserSuspension, authorize } from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// All conflict routes require authentication
router.use(authenticate);
router.use(checkUserSuspension);
router.use(authorize(ROLE_GROUPS.DESK_OPS)); // Officers and admins can resolve conflicts

router.get('/', getUnresolvedConflicts);
router.patch('/:id/resolve', resolveConflict);

export default router;
