import { Router } from 'express';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';
import {
    getAllUsers,
    getUserById,
    updateUserRole,
    deleteUser,
    createUser,
    getSystemSettings,
    updateSystemSettings,
    getAuditLogs,
    getSystemStats,
    getTimeoutMinutes
} from '../controllers/admin.controller.js';

const router = Router();

// All admin routes require authentication
router.use(authenticate);

// User management (admin only)
router.post('/users', authorize(['admin']), createUser);
router.get('/users', authorize(['admin']), getAllUsers);
router.get('/users/:id', authorize(['admin']), getUserById);
router.patch('/users/:id/role', authorize(['admin']), updateUserRole);
router.delete('/users/:id', authorize(['admin']), deleteUser);

// System settings (admin only)
router.get('/settings', authorize(['admin']), getSystemSettings);
router.patch('/settings', authorize(['admin']), updateSystemSettings);

// Audit logs (admin only)
router.get('/audit-logs', authorize(['admin']), getAuditLogs);

// System statistics (accessible by admin and officer)
router.get('/stats', authorize(ROLE_GROUPS.STATS_VIEWERS), getSystemStats);

// Session Timeout Minutes (Accessible by All)
router.get('/timeout', authorize(ROLE_GROUPS.DESK_OPS), getTimeoutMinutes)

export default router;
