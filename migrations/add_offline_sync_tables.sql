-- Migration: Add Offline Sync Tables and Idempotency Key
-- This migration supports the new Offline Sync architecture

-- 1. Create sync_conflicts table for Tier 3 conflict resolution
CREATE TABLE IF NOT EXISTS sync_conflicts (
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

-- 2. Add idempotency_key to reports table for Tier 1 duplicate prevention
ALTER TABLE reports ADD COLUMN IF NOT EXISTS idempotency_key TEXT UNIQUE;
