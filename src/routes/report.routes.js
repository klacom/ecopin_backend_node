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
    updatePropertyOwnerConsent,
    createDisclosureRequest,
    respondToDisclosureRequest,
    getDisclosureRequests
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
router.patch('/:id/disclosure-requests/:disclosureRequestId/respond', respondToDisclosureRequest);
router.get('/:reportId/disclosure-requests', getDisclosureRequests);
router.post('/:reportId/evidence', upload.single('image'), uploadEvidence);
router.get('/:reportId/evidence', getReportEvidence);

// Routes that require LGU/admin role
router.use(authorize(['lgu', 'admin']));
router.patch('/:id/status', updateReportStatus);
router.post('/:id/notes', addReportNote);
router.delete('/:id/photo', deleteReportPhoto);
router.get('/cluster/:clusterId', getReportsByClusterId);
router.post('/:id/photo', beforeAfterUpload.single('image'), uploadReportPhoto);
router.patch('/cluster/:clusterId/complete', batchCompleteReportsByCluster);
router.patch('/:id/property-owner-consent', updatePropertyOwnerConsent);
router.post('/:reportId/disclosure-requests', createDisclosureRequest);

export default router;
