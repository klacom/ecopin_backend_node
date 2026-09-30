-- Migration: Field Crew Operation Log (Phase 4 — Sync Engine)
-- Purpose:
--   Provides the backend-side idempotency store for the Field Crew offline sync engine.
--   Every operation submitted via POST /api/fc/sync/batch is recorded here on first
--   arrival.  Retries with the same operation_id are detected and the original result
--   is returned immediately without re-executing the mutation.
--
-- Design notes:
--   • operation_id is a client-generated UUID (stable, never changes).
--   • result is stored as JSONB so we can return complex per-op payloads on replay.
--   • expires_at lets us prune old log entries; default 30 days.

CREATE TABLE IF NOT EXISTS fc_operation_log (
  operation_id   TEXT        PRIMARY KEY,            -- client UUID
  user_id        UUID        REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_type TEXT        NOT NULL,               -- mirrors FcOutboxOperationType strings
  entity_id      TEXT        NOT NULL,               -- report/task UUID
  entity_type    TEXT        NOT NULL,               -- 'report' | 'task'
  status         TEXT        NOT NULL DEFAULT 'success',  -- 'success' | 'conflict' | 'failed'
  result         JSONB,                              -- serialised result returned to client
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at     TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days')
);

-- Index for fast replay lookups.
CREATE INDEX IF NOT EXISTS idx_fc_operation_log_operation_id
  ON fc_operation_log (operation_id);

-- Index for per-user auditing.
CREATE INDEX IF NOT EXISTS idx_fc_operation_log_user
  ON fc_operation_log (user_id, created_at DESC);

-- Optional: allow Postgres to auto-prune rows after expiry via pg_cron or a manual job.
-- The application also skips expired rows (treats them as unknown), forcing a re-execute.
