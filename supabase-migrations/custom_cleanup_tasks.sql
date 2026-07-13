-- Add is_custom column to cleanup_tasks table
ALTER TABLE cleanup_tasks 
ADD COLUMN IF NOT EXISTS is_custom BOOLEAN DEFAULT FALSE;

-- Add report_ids array column for custom cleanup tasks
ALTER TABLE cleanup_tasks 
ADD COLUMN IF NOT EXISTS report_ids UUID[] DEFAULT NULL;

-- Add index for faster lookups on report_ids
CREATE INDEX IF NOT EXISTS idx_cleanup_tasks_report_ids ON cleanup_tasks USING GIN(report_ids);

-- Add comment
COMMENT ON COLUMN cleanup_tasks.is_custom IS 'Whether this is a custom task (selected reports) or cluster-based task';
COMMENT ON COLUMN cleanup_tasks.report_ids IS 'Array of report IDs for custom cleanup tasks';
