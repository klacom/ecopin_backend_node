import { Router } from 'express';
import { createReport, getMyReports, getPublicReports, getReportById, uploadEvidence, getReportEvidence, upload, updateReportStatus, getReportsByClusterId, batchCompleteReportsByCluster, addReportNote, uploadReportPhoto, beforeAfterUpload, deleteReportPhoto } from '../controllers/report.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';

const router = Router();

// Public routes don't require authentication
router.get('/public', getPublicReports);

// All other report routes require authentication and LGU/admin role
router.use(authenticate);
router.use(authorize(['lgu', 'admin']));

router.post('/', upload.single('image'), createReport);
router.get('/my', getMyReports);
router.get('/:id', getReportById);
router.patch('/:id/status', updateReportStatus);
router.post('/:id/notes', addReportNote);
router.post('/:id/photo', beforeAfterUpload.single('image'), uploadReportPhoto);
router.delete('/:id/photo', deleteReportPhoto);
router.post('/:reportId/evidence', upload.single('image'), uploadEvidence);
router.get('/:reportId/evidence', getReportEvidence);
router.get('/cluster/:clusterId', getReportsByClusterId);
router.patch('/cluster/:clusterId/complete', batchCompleteReportsByCluster);

export default router;
