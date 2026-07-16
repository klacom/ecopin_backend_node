import { Router } from 'express';
import {
    getManualReviewQueue,
    getManualReviewItem,
    assignReviewItem,
    completeReviewItem,
    deleteReviewItem,
    getReviewStats
} from '../controllers/manualReview.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';

const router = Router();

// All manual review routes require authentication
router.use(authenticate);

// Routes for admins to manage manual review queue
router.use(authorize(['admin', 'lgu']));

router.get('/', getManualReviewQueue);
router.get('/stats', getReviewStats);
router.get('/:id', getManualReviewItem);
router.post('/:id/assign', assignReviewItem);
router.post('/:id/complete', completeReviewItem);
router.delete('/:id', deleteReviewItem);

export default router;
