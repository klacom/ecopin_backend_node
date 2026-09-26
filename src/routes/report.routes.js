import { Router } from 'express';
import {
    createReport,
    getMyReports,
    getPublicReports,
    getReportById,
    uploadEvidence,
    getReportEvidence,
    upload,
    mediaUpload,
    updateReportStatus,
    updateReportValidation,
    getReportsByClusterId,
    batchCompleteReportsByCluster,
    addReportNote,
    uploadReportPhoto,
    beforeAfterUpload,
    deleteReportPhoto,
    updatePropertyOwnerConsent,
    lguResolveReport,
    citizenCloseReport,
    getSatisfactionAnalytics,
    createReportFromRejected,
    updateLifecycleStage,
    fetchAgencyResponses,
    updateReportDetails,
    syncReportMedia
} from '../controllers/report.controller.js';
import { batchSyncReports } from '../controllers/sync.controller.js';
import { authenticate, optionalAuthenticate, checkUserSuspension, authorize } from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// Public routes don't require authentication
router.get('/public', getPublicReports);

// Optionally authenticated routes
router.get('/:reportId/evidence', optionalAuthenticate, getReportEvidence);

// All other report routes require authentication
router.use(authenticate);

// Add suspension check for protected routes
router.use(checkUserSuspension);

// Routes that don't need LGU/admin role first
router.post('/sync/batch', batchSyncReports);
router.post('/sync/media/:idempotency_key', mediaUpload.fields([{ name: 'image', maxCount: 5 }, { name: 'video', maxCount: 1 }]), syncReportMedia);
router.post('/', mediaUpload.fields([{ name: 'image', maxCount: 5 }, { name: 'video', maxCount: 1 }]), createReport);
router.get('/my', getMyReports);
router.get('/:id', getReportById);
router.post('/:reportId/evidence', mediaUpload.fields([{ name: 'image', maxCount: 1 }, { name: 'video', maxCount: 1 }]), uploadEvidence);
router.patch('/:id/close', citizenCloseReport); // Citizen can close their own report
router.post('/:id/create-new', createReportFromRejected); // Create new report from rejected
router.get('/cluster/:clusterId', getReportsByClusterId);

// Routes that require officer/admin role
router.use(authorize(ROLE_GROUPS.REPORT_MGMT));
router.get('/analytics/satisfaction', getSatisfactionAnalytics);
router.patch('/:id/status', updateReportStatus);
router.patch('/:id/validation', updateReportValidation);
router.patch('/:id/lifecycle', updateLifecycleStage);
router.patch('/:id/details', updateReportDetails);
router.get('/:id/agency-responses', fetchAgencyResponses);
router.post('/:id/notes', addReportNote);
router.delete('/:id/photo', deleteReportPhoto);

router.post('/:id/photo', beforeAfterUpload.single('image'), uploadReportPhoto);
router.patch('/cluster/:clusterId/complete', batchCompleteReportsByCluster);
router.patch('/:id/property-owner-consent', updatePropertyOwnerConsent);
router.patch('/:id/resolve', lguResolveReport); // LGU resolves report

export default router;
