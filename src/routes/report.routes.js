import { Router } from 'express';
import { createReport, getMyReports, getPublicReports, getReportById } from '../controllers/report.controller.js';
import { authenticate } from '../middleware/auth.middleware.js';

const router = Router();

// All report routes require authentication
router.use(authenticate);

router.post('/', createReport);
router.get('/my', getMyReports);
router.get('/public', getPublicReports);
router.get('/:id', getReportById);

export default router;
