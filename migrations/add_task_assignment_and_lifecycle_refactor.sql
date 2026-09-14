-- Migration: Add task assignment and report lifecycle refactor
-- Description: Add assignment columns to cleanup_tasks, add cleanup_task_id to reports with unique constraint

-- Add assignment columns to cleanup_tasks table
ALTER TABLE cleanup_tasks
ADD COLUMN IF NOT EXISTS assigned_crew_ids UUID[],
ADD COLUMN IF NOT EXISTS assigned_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS assigned_by UUID REFERENCES profiles(id),
ADD COLUMN IF NOT EXISTS last_assigned_at TIMESTAMPTZ;

-- Add cleanup_task_id to reports table
ALTER TABLE reports
ADD COLUMN IF NOT EXISTS cleanup_task_id UUID REFERENCES cleanup_tasks(id);

-- Add unique index to ensure each report can only belong to one cleanup task (excluding nulls)
CREATE UNIQUE INDEX IF NOT EXISTS reports_cleanup_task_id_unique 
ON reports (cleanup_task_id) 
WHERE cleanup_task_id IS NOT NULL;

-- Note: lifecycle_stage column is kept in reports table (not removed)
-- Lifecycle is now updated only via cleanup task operations, not directly from report detail pages
