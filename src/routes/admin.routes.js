import { Router } from 'express';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import {
    getAllUsers,
    getUserById,
    updateUserRole,
    deleteUser,
    getSystemSettings,
    updateSystemSettings,
    getAuditLogs,
    getSystemStats
} from '../controllers/admin.controller.js';

const router = Router();

// All admin routes require authentication and admin role
router.use(authenticate);
router.use(authorize(['admin']));

// User management
router.get('/users', getAllUsers);
router.get('/users/:id', getUserById);
router.patch('/users/:id/role', updateUserRole);
router.delete('/users/:id', deleteUser);

// System settings
router.get('/settings', getSystemSettings);
router.patch('/settings', updateSystemSettings);

// Audit logs
router.get('/audit-logs', getAuditLogs);

// System statistics (accessible by both admin and LGU)
router.get('/stats', authorize(['admin', 'lgu']), getSystemStats);

export default router;
