import {getIncidentCaseRecord} from '../controllers/incident-case-record.controller.js';
import { getReportVideoPolicyHandler, validateReportVideo } from '../services/report-video-policy.service.js';
import { getMyCitizenTrust, getCitizenTrustReview, recordCitizenTrustReview } from '../controllers/citizen-trust.controller.js';
import { getUrgencyQueue, decideReportUrgency } from '../controllers/report-urgency.controller.js';
import {getCrewUrgencyObservations,reviewCrewUrgencyObservation} from '../controllers/crew-urgency.controller.js';
import { fieldReportWrite } from '../middleware/field-report-write.middleware.js';
import {getCleanupProofSource,getCleanupProofOriginal,publishCleanupProof,getPublicCleanupProof,getPublicCleanupProofImage} from '../controllers/cleanup-proof.controller.js';
import { uploadFieldReportPhoto, deleteFieldReportPhoto } from '../controllers/field-report-photo.controller.js';
import { Router } from 'express';
import {
    createReport,
    getMyReports,
    getPublicReports,
    getReportById,
    uploadEvidence,
    getReportEvidence,
    getBatchReportEvidence,
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
    citizenFlagIncomplete,
    citizenWithdrawReport,
    getSatisfactionAnalytics,
    createReportFromRejected,
    updateLifecycleStage,
    fetchAgencyResponses,
    logAgencyResponse,
    updateReportDetails,
    syncReportMedia,
    validateReportImage,
    getStaffReports,
    getReportQuota,
    getBatchReportPublishers
} from '../controllers/report.controller.js';
import { batchSyncReports } from '../controllers/sync.controller.js';
import { authenticate, optionalAuthenticate, checkUserSuspension, authorize } from '../middleware/auth.middleware.js';
import { enforceReportSubmissionQuota } from '../middleware/report-quota.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// Public routes don't require authentication
router.get('/public', getPublicReports);
router.get('/:id/cleanup-proof/public',getPublicCleanupProof);
router.get('/:id/cleanup-proof/public/:proofId/:slot',getPublicCleanupProofImage);

// Citizen reports for authenticated user (must be declared before parameterized /:id route)
router.get('/my', authenticate, checkUserSuspension, getMyReports);
router.get('/trust/me', authenticate, checkUserSuspension, getMyCitizenTrust);

// Citizen daily submission quota status (WT-97)
router.get('/media-policy', authenticate, checkUserSuspension, getReportVideoPolicyHandler);

router.get('/quota', authenticate, checkUserSuspension, getReportQuota);
router.get('/urgent-queue', authenticate, checkUserSuspension, authorize(ROLE_GROUPS.DESK_OPS), getUrgencyQueue);

// Optionally authenticated routes
router.get('/:reportId/evidence', optionalAuthenticate, getReportEvidence);
router.post('/batch-evidence', optionalAuthenticate, getBatchReportEvidence);
router.post('/batch-publishers', optionalAuthenticate, getBatchReportPublishers);
router.get('/:id', optionalAuthenticate, getReportById);

// All other report routes require authentication
router.use(authenticate);

// Add suspension check for protected routes
router.use(checkUserSuspension);
router.get('/:id/case-record',authorize(ROLE_GROUPS.DESK_OPS),getIncidentCaseRecord);
router.get('/:id/cleanup-proof',authorize(ROLE_GROUPS.DESK_OPS),getCleanupProofSource);
router.get('/:id/cleanup-proof/original/:slot',authorize(ROLE_GROUPS.DESK_OPS),getCleanupProofOriginal);
router.post('/:id/cleanup-proof',authorize(ROLE_GROUPS.DESK_OPS),publishCleanupProof);

// Trust reviews are distinct online transactions, never legacy field-report writes.
// The database independently verifies role, ownership, assignment and retry identity.
router.get('/:id/trust-review', authorize(ROLE_GROUPS.DESK_OPS), getCitizenTrustReview);
router.post('/:id/trust-review', authorize(ROLE_GROUPS.DESK_OPS), recordCitizenTrustReview);
router.get('/:id/urgency-observations', authorize(ROLE_GROUPS.REPORT_MGMT), getCrewUrgencyObservations);
router.post('/:id/urgency-observations/:observationId/review', authorize(ROLE_GROUPS.DESK_OPS), reviewCrewUrgencyObservation);
router.post('/:id/urgency', authorize(ROLE_GROUPS.DESK_OPS), decideReportUrgency);

// Pre-validation endpoint for clean photos
router.post('/validate-image', mediaUpload.single('image'), validateReportImage);

// Routes that don't need LGU/admin role first
// New clients use this path when a batch includes hidden reports; old servers return 404 rather than ignoring privacy.
router.post('/sync/batch-protected', batchSyncReports);
router.post('/sync/batch', batchSyncReports);
router.post('/sync/media/:idempotency_key', mediaUpload.fields([{ name: 'image', maxCount: 5 }, { name: 'video', maxCount: 1 }]), validateReportVideo, syncReportMedia);
router.post('/identity-protected', enforceReportSubmissionQuota, mediaUpload.fields([{ name: 'image', maxCount: 5 }, { name: 'clean_image', maxCount: 5 }, { name: 'video', maxCount: 1 }]), validateReportVideo, (req,res,next)=>{req.body.hide_identity=true;return createReport(req,res,next);});
router.post('/', enforceReportSubmissionQuota, mediaUpload.fields([{ name: 'image', maxCount: 5 }, { name: 'clean_image', maxCount: 5 }, { name: 'video', maxCount: 1 }]), validateReportVideo, createReport);
router.post('/:reportId/evidence', mediaUpload.fields([{ name: 'image', maxCount: 1 }, { name: 'video', maxCount: 1 }]), validateReportVideo, uploadEvidence);
router.patch('/:id/close', citizenCloseReport); // Citizen can close their own report
router.patch('/:id/flag-incomplete', citizenFlagIncomplete); // Citizen can flag incomplete cleanup for reinspection
router.delete('/:id', citizenWithdrawReport); // Citizen can withdraw/delete their own report before triage/dispatch
router.patch('/:id/withdraw', citizenWithdrawReport); // Alias for report withdrawal
router.post('/:id/create-new', enforceReportSubmissionQuota, createReportFromRejected); // Create new report from rejected
router.get('/cluster/:clusterId', getReportsByClusterId);

// Routes that require officer/admin role
router.use(authorize(ROLE_GROUPS.REPORT_MGMT));
router.use(fieldReportWrite);
router.get('/', getStaffReports);
router.get('/analytics/satisfaction', getSatisfactionAnalytics);
router.patch('/:id/status', updateReportStatus);
router.patch('/:id/validation', updateReportValidation);
router.patch('/:id/lifecycle', updateLifecycleStage);
router.patch('/:id/details', updateReportDetails);
router.get('/:id/agency-responses', fetchAgencyResponses);
router.post('/:id/agency-responses', logAgencyResponse);
router.post('/:id/notes', addReportNote);
router.delete('/:id/photo', (req,res,next) => req.user.role === 'field_crew' ? deleteFieldReportPhoto(req,res,next) : deleteReportPhoto(req,res,next));

router.post('/:id/photo', beforeAfterUpload.single('image'), (req,res,next) => req.user.role === 'field_crew' ? uploadFieldReportPhoto(req,res,next) : uploadReportPhoto(req,res,next));
router.patch('/cluster/:clusterId/complete', batchCompleteReportsByCluster);
router.patch('/:id/property-owner-consent', updatePropertyOwnerConsent);
router.patch('/:id/resolve', lguResolveReport); // LGU resolves report

export default router;
