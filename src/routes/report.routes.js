import { Router } from 'express';
import { createReport, getMyReports, getPublicReports, getReportById, uploadEvidence, getReportEvidence, upload, updateReportStatus, getReportsByClusterId, batchCompleteReportsByCluster } from '../controllers/report.controller.js';
import { authenticate } from '../middleware/auth.middleware.js';

const router = Router();

// All report routes require authentication
router.use(authenticate);

router.post('/', upload.single('image'), createReport);
router.get('/my', getMyReports);
router.get('/public', getPublicReports);
router.get('/:id', getReportById);
router.patch('/:id/status', updateReportStatus);
router.post('/:reportId/evidence', upload.single('image'), uploadEvidence);
router.get('/:reportId/evidence', getReportEvidence);
router.get('/cluster/:clusterId', getReportsByClusterId);
router.patch('/cluster/:clusterId/complete', batchCompleteReportsByCluster);

export default router;
