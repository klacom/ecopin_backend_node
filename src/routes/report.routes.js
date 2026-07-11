import { Router } from 'express';
import { 
    createReport, 
    getMyReports, 
    getPublicReports, 
    getReportById, 
    uploadEvidence, 
    getReportEvidence, 
    upload, 
    updateReportStatus, 
    getReportsByClusterId, 
    batchCompleteReportsByCluster, 
    addReportNote, 
    uploadReportPhoto, 
    beforeAfterUpload, 
    deleteReportPhoto, 
    updateLifecycleStage, 
    acknowledgeComplaint, 
    logAgencyResponse, 
    fetchAgencyResponses,
    updatePropertyOwnerConsent
} from '../controllers/report.controller.js';
import { authenticate, authorize } from '../middleware/auth.middleware.js';

const router = Router();

// Public routes don't require authentication
router.get('/public', getPublicReports);

// All other report routes require authentication
router.use(authenticate);

// Routes that don't need LGU/admin role first
router.post('/', upload.single('image'), createReport);
router.get('/my', getMyReports);
router.get('/:id', getReportById);
router.post('/:reportId/evidence', upload.single('image'), uploadEvidence);
router.get('/:reportId/evidence', getReportEvidence);

// Routes that require LGU/admin role
router.use(authorize(['lgu', 'admin']));
router.patch('/:id/status', updateReportStatus);
router.patch('/:id/lifecycle-stage', updateLifecycleStage);
router.post('/:id/acknowledge', acknowledgeComplaint);
router.post('/:id/agency-response', logAgencyResponse);
router.get('/:id/agency-responses', fetchAgencyResponses);
router.post('/:id/notes', addReportNote);
router.delete('/:id/photo', deleteReportPhoto);
router.get('/cluster/:clusterId', getReportsByClusterId);
router.post('/:id/photo', beforeAfterUpload.single('image'), uploadReportPhoto);
router.patch('/cluster/:clusterId/complete', batchCompleteReportsByCluster);
router.patch('/:id/property-owner-consent', updatePropertyOwnerConsent);

export default router;
