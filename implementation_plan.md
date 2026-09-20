# Offline Sync — EcoPin Implementation Plan

## Overview

This plan implements **seamless offline-first synchronization** for two distinct user flows:

1. **Citizens** submitting waste/flood/pollution reports while offline (photos + metadata stored locally → auto-synced when connectivity returns)
2. **Field Crew** updating task statuses (e.g., mark task in-progress, complete, upload before/after photos) while in low-coverage areas → auto-pushed on reconnection

The system is modeled after Google Docs' optimistic local-first approach: the app writes to a local queue immediately and gives instant UI feedback, while a background sync engine drains the queue as connectivity allows.

---

## Conflict Resolution Strategy

> [!IMPORTANT]
> **Resolved: Three-Tier Strategy — Last-Write-Wins with Server-Side Timestamp Authority + Ground-Truth Field Priority**

### The Conflict Scenario

LGU Crew A and LGU Crew B both pick up cleanup tasks offline. When both sync, they may attempt to update the same report's `status` or `lifecycle_stage` simultaneously. Alternatively, an Officer might update a task's administrative details from the dashboard while the assigned Field Crew is offline updating its completion status on-site.

### Recommended Approach: Optimistic Locking via `updated_at` + Field-Level Authority

| Strategy | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Last-Write-Wins (server timestamp)** | Simple, no extra schema | Silent data loss on concurrent edits | ❌ Risky for critical field ops |
| **Last-Write-Wins + `updated_at` guard** | Easy, prevents stale overwrite | One crew still loses their change | ✅ Base layer |
| **Field-Level Authority (Ground Truth)** | Protects actual on-site data | Requires field mapping logic | ✅ Base layer |
| **Operational Transform (OT)** | Merge granular field edits | Very complex to implement | ❌ Overkill |
| **Server-arbitrated conflict queue** | Human review for conflicts | Manual overhead | ✅ Escalation layer |

**Decision**: Use a **three-tier conflict resolution architecture**:

1. **Tier 1 — Optimistic locking**: Every sync operation carries the client's known `updated_at`. The backend rejects the operation if `server.updated_at > client.known_updated_at` (HTTP 409 Conflict).
2. **Tier 2 — Field-Level Authority (Ground Truth Priority)**: If a conflict occurs between an Officer and a Field Crew member, resolution depends on the specific fields modified:
* **Execution Fields (`status`, `lifecycle_stage`, `evidence_photos`)**: Field Crew updates automatically override Officer updates, ensuring on-site ground truth is preserved.
* **Administrative Fields (`priority_level`, `assigned_team`, `issue_category`)**: Officer updates automatically override Field Crew updates.
* **Same-Role Clashes**: Ties between users of the exact same role go to the earlier timestamp.


3. **Tier 3 — Strict Manual Review (Conflict Queue)**: If an Officer and a Field Crew member both explicitly update a task's `status` at the exact same time, the system rejects the auto-merge. All rejected sync operations are logged in a `sync_conflicts` Supabase table and surfaced in the officer dashboard for manual verification.

### Known Issues to Address

| # | Issue | Mitigation |
| --- | --- | --- |
| 1 | **Duplicate report creation** — Citizen submits a report offline twice due to retry | Assign a client-generated `idempotency_key` (UUID) before submit. Backend deduplicates by `idempotency_key`. |
| 2 | **Media file not available on sync** — Photo taken offline, file deleted before sync | Store media in app's Documents directory (not cache). Validate file existence before queuing sync. |
| 3 | **Expired JWT on sync** — Token is stale when connectivity returns | Re-authenticate silently using Supabase `refreshSession()` before each sync batch (already partially done in `ApiClient`). |
| 4 | **Cloudinary upload fails mid-sync** — Network drops again during media upload | Break into two-phase commit: (a) upload media → get URL (b) submit report with URL. Queue each phase separately. Retry each phase independently. |
| 5 | **Stale offline data** — Crew views an outdated task status while offline | Cache last-fetched server state with a `cached_at` timestamp; show a "Last updated X min ago (offline)" banner. |
| 6 | **Large media queue hogs bandwidth** — Multiple crew members sync huge videos at once | Sync text/metadata immediately; queue media uploads as low-priority background tasks with exponential back-off. **Action: Limit offline citizen reports to photos only (max 5).** |
| 7 | **SQLite schema mismatch after app update** | Use `drift` with versioned migrations. Increment DB version on each schema change. |
| 8 | **Concurrent sync from same device** — App re-opens while a background sync is running | Use a `SyncLock` (simple boolean flag + timestamp in SharedPreferences) to prevent double-sync. |
| 9 | **Queue Auto-Expiry** — Stale operations piling up | Soft-delete unsynced citizen reports after 7 days, and task updates after 30 days. Notify the user upon expiry. |

---

## Architecture Summary

```
Flutter App (Offline-First)
├── Local DB (drift/SQLite)
│   ├── offline_report_queue    ← pending citizen reports (auto-expires in 7 days)
│   ├── offline_task_updates    ← pending field crew updates (auto-expires in 30 days)
│   ├── cached_reports          ← read cache for map/list views
│   └── sync_metadata           ← last_synced_at, sync_lock, etc.
├── SyncEngine (background isolate-safe service)
│   ├── Watches connectivity changes
│   ├── Drains queues in order (metadata first, media second)
│   ├── Handles 409 conflicts → logs to conflict store
│   └── Emits sync status events → UI banners
└── UI Layer
    ├── Optimistic updates (show pending items immediately)
    ├── Offline banner (persistent when disconnected)
    └── Sync status indicator (pending count, last synced)

Node.js Backend (New Endpoints)
├── POST /api/sync/reports (batch report creation with idempotency)
├── POST /api/sync/task-updates (batch task status updates with field-level authority logic)
├── POST /api/sync/conflicts (log unresolvable Tier 3 conflicts)
└── GET  /api/sync/conflicts (officer dashboard: view conflicts)

```

---

## Proposed Changes

### Flutter App — New Packages

Add to `pubspec.yaml`:

```yaml
drift: ^2.23.1          # SQLite ORM with type-safe migrations
drift_sqflite: ^2.7.0   # sqflite backend for drift
path_provider: ^2.1.5   # get app Documents dir for media storage
sqflite: ^2.4.2         # underlying SQLite

```

> [!NOTE]
> `shared_preferences` is already in `pubspec.yaml` and will be used for sync lock/metadata. `connectivity_plus` is already present.

---

### Layer 1 — Local Database (Flutter)

#### `lib/core/database/app_database.dart`

Drift database definition with tables:

* `OfflineReportQueue` — stores pending citizen report submissions (title, description, lat, lng, imagePaths JSON (photos only), status: `pending | syncing | failed`, idempotencyKey, createdAt)
* `OfflineTaskUpdates` — stores pending field crew actions (taskId, reportId, actionType: `update_status | upload_photo | mark_complete`, payload JSON, status, idempotencyKey, createdAt)
* `CachedReports` — local read cache (report JSON blob, cachedAt, serverUpdatedAt)
* `SyncConflicts` — local log of server-rejected operations (operation JSON, conflictReason, resolvedAt nullable)

#### `lib/core/database/daos/offline_queue_dao.dart`

Type-safe data access object for `OfflineReportQueue` and `OfflineTaskUpdates`.

#### `lib/core/database/daos/cached_reports_dao.dart`

Read/write access to `CachedReports`.

---

### Layer 2 — Sync Engine (Flutter)

#### `lib/core/services/sync_engine.dart`

The central sync coordinator. Key responsibilities:

* Subscribes to `connectivityProvider` stream (already exists)
* On connectivity restored → acquires `SyncLock` → calls `SyncEngine.syncAll()`
* `syncAll()`:
1. Refresh JWT via `Supabase.refreshSession()`
2. Drain `offline_report_queue` → calls backend `/api/sync/reports`
3. Drain `offline_task_updates` → calls backend `/api/sync/task-updates`
4. On 409 → write to `SyncConflicts`, notify user
5. On success → delete from queue, update cache
6. Release `SyncLock`


* Exposes `syncStatusProvider` (Riverpod `StateNotifierProvider`) → UI subscribes

#### `lib/core/services/media_upload_queue.dart`

Handles deferred media uploads as a separate lower-priority queue:

* Phase 1: Upload file to Cloudinary via `/api/reports/{id}/photo` or evidence endpoint
* Phase 2: Patch the report/task with the returned URL
* Retries with exponential backoff (1s → 2s → 4s → max 60s)

---

### Layer 3 — Modified Flutter Services

#### `connectivity_service.dart`

Expand from a simple stream to a full `ConnectivityService` class with:

* `isOnline` getter
* `onConnectivityRestored` callback hook (called by `SyncEngine`)
* Caches last known connectivity state

#### `api_service.dart`

Add two new methods:

* `syncReports(List<Map> queue)` → `POST /api/sync/reports`
* `syncTaskUpdates(List<Map> queue)` → `POST /api/sync/task-updates`

Wrap all API calls in connectivity check: if offline → queue operation locally and return a synthetic "queued" response to the caller.

---

### Layer 4 — Modified Flutter UI

#### `lib/shared/reports/presentation/` — Report submission flow

Intercept "Submit Report" action:

* If **online**: current behavior (direct API call)
* If **offline**: write to `offline_report_queue`, show success snackbar with "📵 Report saved offline — will sync automatically"

#### Field crew task update actions (status changes, photo uploads)

In `fc_cluster_detail_screen.dart` and related widgets:

* Wrap task status updates with the same offline-first interception
* Show pending indicator badge on tasks with unsynced changes

#### `lib/shared/widgets/offline_sync_banner.dart`

Persistent top banner shown when offline:

```
📵 You're offline — 3 changes pending sync

```

Dismissible, shows live pending count from `syncStatusProvider`.

#### `lib/shared/widgets/sync_status_indicator.dart`

Small icon in app bars showing:

* ✅ Synced (green dot)
* 🔄 Syncing... (spinning)
* ⚠️ X items pending (amber with count)
* ❌ Sync failed (red, tappable to retry)

---

### Backend — New Sync Endpoints

#### `report.routes.js`

Add:

```js
router.post('/sync/batch', authenticate, checkUserSuspension, batchSyncReports);

```

#### `cleanup_task.routes.js`

Add:

```js
router.post('/sync/batch', authenticate, authorize(ROLE_GROUPS.FIELD_CREW), batchSyncTaskUpdates);

```

#### `src/controllers/sync.controller.js`

Two handlers:

**`batchSyncReports`**: Accepts an array of pending report creations. For each:

1. Check `idempotency_key` — if already exists, return existing report ID (skip duplicate)
2. Call existing `createReport` logic
3. Return array of `{ idempotency_key, result: 'created' | 'duplicate' | 'error', report_id, error_message }`

**`batchSyncTaskUpdates`**: Accepts an array of task/report update operations. For each:

1. Check `client_known_updated_at` vs `server.updated_at` (optimistic lock).
2. If stale → run Tier 2 Field-Level Authority check (e.g., did Field Crew update an execution field?).
3. If Tier 2 resolves the conflict → apply update.
4. If Tier 3 conflict (unresolvable status clash) → return `{ status: 'conflict', server_record: {...} }` and insert into `sync_conflicts` Supabase table.

#### `src/controllers/conflict.controller.js`

* `GET /api/sync/conflicts` — paginated list of unresolved conflicts (officer dashboard)
* `PATCH /api/sync/conflicts/:id/resolve` — officer manually resolves conflict

#### Supabase Migration — `sync_conflicts` table

```sql
CREATE TABLE sync_conflicts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id),
  operation_type TEXT NOT NULL,  -- 'report_create' | 'task_update'
  operation_payload JSONB NOT NULL,
  conflict_reason TEXT NOT NULL,
  server_state JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id),
  resolution_notes TEXT
);

```

#### `reports` table

Add column: `idempotency_key TEXT UNIQUE` — prevents duplicate report creation on retry.

---

## Resolved Open Questions

> [!IMPORTANT]
> **Q1: Should citizens be able to submit reports with large videos while offline?**
> **Resolution:** Limit offline reports to photos only (max 5 images). Storing and syncing 50–100MB videos offline is too risky for local storage and bandwidth constraints.

> [!IMPORTANT]
> **Q2: Should the sync queue persist across app restarts?**
> **Resolution:** Yes. SQLite (`drift`) will be used to ensure the queue survives force-closes and device reboots.

> [!NOTE]
> **Q3: How long should unsynced items be retained before auto-expiry?**
> **Resolution:** 7 days for unsynced citizen reports, 30 days for task updates. After expiry, soft-delete from the local queue and notify the user.

> [!NOTE]
> **Q4: For field crew conflicts — how do we handle team leads vs regular crew?**
> **Resolution:** Field Crew has execution priority over Officers. If a `team_lead` role exists on the ground, they will hold priority over standard `field_crew` for execution fields in the event of a same-team conflict.

> [!NOTE]
> **Q5: Should the conflict dashboard be in the Next.js web app (`ecopin-web`) in addition to the mobile app?**
> **Resolution:** Yes. Exposing the `sync_conflicts` table to the Next.js dashboard is the primary way Officers will manually resolve Tier 3 status clashes.

---

## Verification Plan

### Automated Tests

* `flutter test` — unit tests for `SyncEngine` (mock connectivity, mock DB, assert queue drain behavior)
* `jest` (backend) — test `batchSyncReports` with duplicate `idempotency_key`, test 409 conflict detection, and Tier 2/Tier 3 logic.

### Manual Verification

1. Put device in **Airplane Mode** → submit a citizen report → confirm "saved offline" message.
2. Turn **Wi-Fi back on** → confirm report appears in the map within seconds.
3. **Conflict test**: Submit conflicting task updates from two devices offline (e.g., test Tier 2 override by updating an execution field as a crew member and an admin field as an officer) → sync both → confirm expected resolution or Tier 3 escalation in the dashboard.
4. **App restart test**: Queue items offline, force-close app, reopen → items still pending → restore connectivity → sync completes.
5. **Media test**: Take 5 photos offline → queue → sync → confirm all photos appear on the report.