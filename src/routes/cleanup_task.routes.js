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
    upload
} from '../controllers/cleanup_task.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// All cleanup task routes require authentication
router.use(authenticate);

// Except this
router.get('/cluster/:clusterId', getTasksByClusterId);
router.use(authorize(ROLE_GROUPS.FIELD_OPS));

router.post('/', createCleanupTask);
router.post('/custom', createCustomCleanupTask);
router.get('/', getAllCleanupTasks);
router.get('/:id', getCleanupTaskById);

router.post('/:taskId/photo', upload.single('image'), uploadCleanupPhoto);
router.delete('/:taskId/photo', deleteCleanupPhoto);
router.patch('/:id/complete', markTaskComplete);

export default router;
