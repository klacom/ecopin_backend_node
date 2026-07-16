import { Router } from 'express';
import {
    issueStrike,
    getUserStrikes,
    getAllStrikes,
    updateStrike,
    deleteStrike,
    getUserSuspensionStatus,
    liftSuspension
} from '../controllers/strike.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';

const router = Router();

// All strike routes require authentication
router.use(authenticate);

// Routes for users to view their own strikes
router.get('/my', getUserStrikes);
router.get('/my/suspension-status', (req, res, next) => {
    req.params.userId = req.user.id;
    getUserSuspensionStatus(req, res, next);
});

// Routes for admins to manage strikes
router.use(authorize(['admin', 'lgu']));

router.post('/', issueStrike);
router.get('/all', getAllStrikes);
router.get('/user/:userId', getUserStrikes);
router.get('/user/:userId/suspension-status', getUserSuspensionStatus);
router.patch('/:id', updateStrike);
router.delete('/:id', deleteStrike);
router.post('/user/:userId/lift-suspension', liftSuspension);

export default router;
