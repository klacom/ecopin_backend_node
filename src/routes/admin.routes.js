import { Router } from 'express';
import { prepareCmsMedia, completeCmsMedia } from '../controllers/cms-upload.controller.js';
import { authenticate, checkUserSuspension, authorize } from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';
import {
    getAllUsers,
    getUserById,
    updateUserRole,
    deleteUser,
    createUser,
    changeUserPassword,
    getSystemSettings,
    updateSystemSettings,
    getCmsSettings,
    updateCmsSettings,
    uploadCmsMedia,
    getAuditLogs,
    getSystemLogs,
    getSystemStats,
    getTimeoutMinutes,
    getAuditArchiveStatus,
    executeAuditArchive,
    getDisasterRecoveryStatusHandler,
    verifyStorageReplicationHandler,
    executeDisasterRecoveryDrillHandler,
    getInfrastructureEncryptionStatusHandler,
    verifyDomainTlsHandler,
    getApmStatusHandler,
    testApmAlertHandler,
    getEnvironmentAuditHandler,
    verifyPreviewIsolationHandler,
    getGitHistoryAuditHandler,
    verifyGitCleanlinessHandler
} from '../controllers/admin.controller.js';



const router = Router();

// All admin routes require authentication
router.use(authenticate);

// Add suspension check for protected routes
router.use(checkUserSuspension);

// Session Timeout Minutes (Accessible by All Authenticated Users)
router.get('/timeout', getTimeoutMinutes);

// User management (admin only)
router.post('/users', authorize(['admin']), createUser);
router.get('/users', authorize(['admin']), getAllUsers);
router.get('/users/:id', authorize(['admin']), getUserById);
router.patch('/users/:id/role', authorize(['admin']), updateUserRole);
router.patch('/users/:id/password', authorize(['admin']), changeUserPassword);
router.delete('/users/:id', authorize(['admin']), deleteUser);

import multer from 'multer';

const cmsStorage = multer.memoryStorage();
const cmsUpload = multer({
    storage: cmsStorage,
    limits: {
        fileSize: 50 * 1024 * 1024 // Up to 50MB for media and APK bundles
    },
    fileFilter: (req, file, cb) => {
        const allowedTypes = ['image/jpeg', 'image/png', 'image/webp', 'image/svg+xml', 'application/vnd.android.package-archive', 'application/octet-stream'];
        if (allowedTypes.includes(file.mimetype) || file.originalname.endsWith('.apk')) {
            cb(null, true);
        } else {
            cb(new Error('Invalid file type. Allowed types: Images (JPG, PNG, WebP, SVG) and APK bundles.'), false);
        }
    }
});

// System settings (admin only)
router.get('/settings', authorize(['admin']), getSystemSettings);
router.patch('/settings', authorize(['admin']), updateSystemSettings);
router.get('/settings/cms', authorize(['admin']), getCmsSettings);
router.patch('/settings/cms', authorize(['admin']), updateCmsSettings);
router.post('/settings/cms/upload', authorize(['admin']), cmsUpload.single('file'), uploadCmsMedia);
router.post('/settings/cms/upload/prepare', authorize(['admin']), prepareCmsMedia);
router.post('/settings/cms/upload/complete', authorize(['admin']), completeCmsMedia);

// System logs (authentication, session activity, admin only)
router.get('/system-logs', authorize(['admin']), getSystemLogs);

// Operational audit logs & WORM archival (who, what, target, timestamp, admin only)
router.get('/audit-logs/archive-status', authorize(['admin']), getAuditArchiveStatus);
router.post('/audit-logs/archive', authorize(['admin']), executeAuditArchive);
router.get('/audit-logs', authorize(['admin']), getAuditLogs);

// Disaster Recovery & Storage Bucket Cross-Region Replication (admin only)
router.get('/disaster-recovery/status', authorize(['admin']), getDisasterRecoveryStatusHandler);
router.post('/disaster-recovery/verify-replication', authorize(['admin']), verifyStorageReplicationHandler);
router.post('/disaster-recovery/drill', authorize(['admin']), executeDisasterRecoveryDrillHandler);

// Platform Encryption at Rest & Transport Security (admin only, WT-50)
router.get('/infrastructure/encryption-status', authorize(['admin']), getInfrastructureEncryptionStatusHandler);
router.post('/infrastructure/verify-domain-tls', authorize(['admin']), verifyDomainTlsHandler);

// Production APM Monitoring, PII Scrubbing & Critical Alert Delivery (admin only, WT-47)
router.get('/infrastructure/apm-status', authorize(['admin']), getApmStatusHandler);
router.post('/infrastructure/test-apm-alert', authorize(['admin']), testApmAlertHandler);

// Staging & Preview Deployment Environment Access Controls & Isolation Audit (admin only, WT-42)
router.get('/infrastructure/environment-audit', authorize(['admin']), getEnvironmentAuditHandler);
router.post('/infrastructure/verify-preview-isolation', authorize(['admin']), verifyPreviewIsolationHandler);

// Git Remote History, Deleted Branches & Repository Visibility Audit (admin only, WT-36)
router.get('/infrastructure/git-history-audit', authorize(['admin']), getGitHistoryAuditHandler);
router.post('/infrastructure/verify-git-cleanliness', authorize(['admin']), verifyGitCleanlinessHandler);



// System statistics (accessible by admin and officer)
router.get('/stats', authorize(ROLE_GROUPS.STATS_VIEWERS), getSystemStats);

export default router;
