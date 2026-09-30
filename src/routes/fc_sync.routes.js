/**
 * fc_sync.routes.js
 *
 * Routes for the Phase 4 Field Crew offline sync engine.
 *
 *   POST /api/fc/sync/batch
 *     Accepts up to 50 Field Crew outbox operations in one request.
 *     Requires authentication; accessible to field_crew, officer, and admin.
 *
 * Photo sync (fc.photo.*) is NOT handled here because multipart uploads cannot
 * be batched in a JSON body.  The existing per-entity endpoints are used by
 * FcPhotoSyncManager instead.
 */

import { Router } from 'express';
import { batchFcSync } from '../controllers/fc_sync.controller.js';
import {
  authenticate,
  checkUserSuspension,
  authorize,
} from '../middleware/auth.middleware.js';
import { ROLE_GROUPS } from '../constants/roles.js';

const router = Router();

// All FC sync routes require a valid Supabase JWT.
router.use(authenticate);
router.use(checkUserSuspension);

// Accessible to field_crew, officer, and admin (FIELD_OPS group).
router.post('/batch', authorize(ROLE_GROUPS.FIELD_OPS), batchFcSync);

export default router;
