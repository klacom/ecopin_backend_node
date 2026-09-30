-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: Phase 5 — Server-Side Versioning and Conflict Audit
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Problem with device-clock ordering
-- ────────────────────────────────────
-- updated_at is set by the server on every write, but two concurrent writes
-- that arrive at the server within the same millisecond (or from devices with
-- drifted clocks) can produce the same timestamp, making conflict detection
-- unreliable.
--
-- Solution: monotonic integer sequence column
-- ────────────────────────────────────────────
-- fc_version is incremented by the server on every accepted write using a
-- Postgres sequence.  It is strictly monotonic per-table, never reuses a
-- value, and is independent of device clocks.
--
-- The client sends `base_version` (the fc_version it last saw) with every
-- mutation.  The server rejects or merges any mutation whose base_version
-- does not match the current fc_version, preventing stale-write overwrites.
--
-- fc_conflict_audit table
-- ────────────────────────
-- Every rejected or merged mutation is written here so SWMO admins can
-- investigate.  Field crew users are shown a concise summary ("1 change
-- was not applied") without exposing raw SQL or JSON to them.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Shared sequence — one atomic counter for all FC versioned entities.
--    Using a single sequence (rather than per-row auto-increment) means every
--    write anywhere gets a globally unique, ordered version number.
CREATE SEQUENCE IF NOT EXISTS fc_version_seq
  START WITH 1
  INCREMENT BY 1
  NO CYCLE;

-- 2. Add fc_version to reports.
--    Default 0 so existing rows are valid; the first accepted write bumps them.
ALTER TABLE reports
  ADD COLUMN IF NOT EXISTS fc_version BIGINT NOT NULL DEFAULT 0;

-- Index for fast version-check queries.
CREATE INDEX IF NOT EXISTS idx_reports_fc_version
  ON reports (id, fc_version);

-- 3. Add fc_version to cleanup_tasks.
ALTER TABLE cleanup_tasks
  ADD COLUMN IF NOT EXISTS fc_version BIGINT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_cleanup_tasks_fc_version
  ON cleanup_tasks (id, fc_version);

-- 4. Conflict audit table.
--    Written for every operation that was rejected, merged, or applied over
--    a stale base_version.  Never updated — append-only.
CREATE TABLE IF NOT EXISTS fc_conflict_audit (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The stable client-generated operation UUID (matches fc_operation_log).
  operation_id    TEXT        NOT NULL,

  -- Who submitted the operation.
  user_id         UUID        REFERENCES auth.users(id) ON DELETE SET NULL,

  -- What kind of operation was attempted.
  operation_type  TEXT        NOT NULL,

  -- The entity this mutation targets.
  entity_id       TEXT        NOT NULL,
  entity_type     TEXT        NOT NULL,   -- 'report' | 'task'

  -- Outcome:
  --   'merged'   — applied, but over a stale base_version (field-authority resolved it)
  --   'rejected' — not applied; first-accepted-wins rule gave priority to another op
  --   'idempotent' — operation was a no-op (e.g. duplicate ack, same status)
  outcome         TEXT        NOT NULL,

  -- The version the client thought the entity was at when it created this op.
  client_base_version BIGINT,

  -- The version the server actually had when it processed this op.
  server_version  BIGINT      NOT NULL,

  -- Snapshot of the payload the client sent.
  payload         JSONB       NOT NULL,

  -- Snapshot of the server state at the time of processing (for admin review).
  server_state_snapshot JSONB,

  -- Human-readable reason stored for admin dashboards.
  reason          TEXT,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for admin queries: "show me all conflicts for this report".
CREATE INDEX IF NOT EXISTS idx_fc_conflict_audit_entity
  ON fc_conflict_audit (entity_id, entity_type, created_at DESC);

-- Index for admin queries: "show me all conflicts by this user".
CREATE INDEX IF NOT EXISTS idx_fc_conflict_audit_user
  ON fc_conflict_audit (user_id, created_at DESC);

-- Index for linking back to the operation log.
CREATE INDEX IF NOT EXISTS idx_fc_conflict_audit_operation
  ON fc_conflict_audit (operation_id);

-- 5. Supabase RPC wrapper so the Node backend can call nextval() via supabase.rpc().
--    Security: only authenticated users can call this (default RLS on functions).
CREATE OR REPLACE FUNCTION nextval(seq_name TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN nextval(seq_name::regclass);
END;
$$;

-- 6. Photo hash columns for server-side duplicate detection (Phase 5).
--    Stores the SHA-256 hex digest of the last accepted before/after photo
--    so a second upload of the identical file is short-circuited.
ALTER TABLE reports
  ADD COLUMN IF NOT EXISTS before_photo_hash TEXT,
  ADD COLUMN IF NOT EXISTS after_photo_hash  TEXT;

ALTER TABLE cleanup_tasks
  ADD COLUMN IF NOT EXISTS before_photo_hash TEXT,
  ADD COLUMN IF NOT EXISTS after_photo_hash  TEXT;
