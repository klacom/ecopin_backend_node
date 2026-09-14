import { Router } from 'express';
import {
    createCleanupTask,
    createCustomCleanupTask,
    getAllCleanupTasks,
    getCleanupTaskById,
    uploadCleanupPhoto,
    deleteCleanupPhoto,
    markTaskComplete,
    getTasksByClusterId,
    assignCleanupTask,
    getAvailableCrew,
    upload
} from '../controllers/cleanup_task.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// All cleanup task routes require authentication
router.use(authenticate);

// Public endpoint (no auth required for cluster tasks)
router.get('/cluster/:clusterId', getTasksByClusterId);

// Routes requiring field ops role (officer, field crew, admin)
router.use(authorize(ROLE_GROUPS.FIELD_OPS));

router.post('/', createCleanupTask);
router.post('/custom', createCustomCleanupTask);
router.get('/', getAllCleanupTasks);
router.get('/available-crew', getAvailableCrew);
router.get('/:id', getCleanupTaskById);

// Assignment routes (officer only)
router.patch('/:id/assign', authorize(ROLE_GROUPS.DESK_OPS), assignCleanupTask);

// Photo upload routes
router.post('/:taskId/photo', upload.single('image'), uploadCleanupPhoto);
router.delete('/:taskId/photo', deleteCleanupPhoto);

// Task completion (field crew only)
router.patch('/:id/complete', markTaskComplete);

export default router;
