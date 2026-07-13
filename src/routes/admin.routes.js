import { Router } from 'express';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import {
    getAllUsers,
    getUserById,
    updateUserRole,
    deleteUser,
    createUser,
    getSystemSettings,
    updateSystemSettings,
    getAuditLogs,
    getSystemStats
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

// System statistics (accessible by both admin and LGU)
router.get('/stats', authorize(['admin', 'lgu']), getSystemStats);

export default router;
