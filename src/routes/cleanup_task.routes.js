import { Router } from 'express';
import {
    createCleanupTask,
    getAllCleanupTasks,
    getCleanupTaskById,
    uploadCleanupPhoto,
    markTaskComplete,
    getTasksByClusterId,
    upload
} from '../controllers/cleanup_task.controller.js';
import { authenticate } from '../middleware/auth.middleware.js';

const router = Router();

// All cleanup task routes require authentication
router.use(authenticate);

router.post('/', createCleanupTask);
router.get('/', getAllCleanupTasks);
router.get('/:id', getCleanupTaskById);
router.get('/cluster/:clusterId', getTasksByClusterId);
router.post('/:taskId/photo', upload.single('image'), uploadCleanupPhoto);
router.patch('/:id/complete', markTaskComplete);

export default router;
