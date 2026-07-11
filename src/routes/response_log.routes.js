import { Router } from 'express';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import { getResponseLogs } from '../controllers/response_log.controller.js';

const router = Router();

// All response log routes require authentication and LGU or admin role
router.use(authenticate);
router.use(authorize(['lgu', 'admin']));

// Get response logs
router.get('/', getResponseLogs);

export default router;
