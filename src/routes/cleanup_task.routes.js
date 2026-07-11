import { Router } from 'express';
import {
    createCleanupTask,
    getAllCleanupTasks,
    getCleanupTaskById,
    uploadCleanupPhoto,
    deleteCleanupPhoto,
    markTaskComplete,
    getTasksByClusterId,
    upload
} from '../controllers/cleanup_task.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';

const router = Router();

// All cleanup task routes require authentication and LGU/admin role
router.use(authenticate);

// Except this
router.get('/cluster/:clusterId', getTasksByClusterId);
router.use(authorize(['lgu', 'admin']));

router.post('/', createCleanupTask);
router.get('/', getAllCleanupTasks);
router.get('/:id', getCleanupTaskById);

router.post('/:taskId/photo', upload.single('image'), uploadCleanupPhoto);
router.delete('/:taskId/photo', deleteCleanupPhoto);
router.patch('/:id/complete', markTaskComplete);

export default router;
