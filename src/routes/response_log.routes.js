import { Router } from 'express';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import { getResponseLogs } from '../controllers/response_log.controller.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// All response log routes require authentication and field ops role
router.use(authenticate);
router.use(authorize(ROLE_GROUPS.FIELD_OPS));

// Get response logs
router.get('/', getResponseLogs);

export default router;
