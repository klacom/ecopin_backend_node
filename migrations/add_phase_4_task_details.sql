-- Migration: Add Phase 4 Task Details
-- Description: Adds operational fields to cleanup_tasks to provide full context to field crews

ALTER TABLE cleanup_tasks
  ADD COLUMN IF NOT EXISTS required_resources TEXT,
  ADD COLUMN IF NOT EXISTS expected_action TEXT,
  ADD COLUMN IF NOT EXISTS scheduled_date DATE;
