-- 1. Create ENUMs
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cleanup_task_status') THEN
        CREATE TYPE cleanup_task_status AS ENUM (
            'created', 'pending', 'in_progress', 'partially_completed', 'completed', 'cancelled'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cleanup_task_type') THEN
        CREATE TYPE cleanup_task_type AS ENUM (
            'Cleanup', 'Investigation', 'Verification', 'Emergency Response', 
            'Reinspection', 'Monitoring', 'Escalation', 'Deferred'
        );
    END IF;
END
$$;

-- 2. Drop constraints
ALTER TABLE cleanup_tasks DROP CONSTRAINT IF EXISTS cleanup_tasks_task_type_check;

-- 3. Drop defaults
ALTER TABLE cleanup_tasks ALTER COLUMN status DROP DEFAULT;
ALTER TABLE cleanup_tasks ALTER COLUMN task_type DROP DEFAULT;

-- 4. Alter columns
ALTER TABLE cleanup_tasks ALTER COLUMN status TYPE cleanup_task_status USING status::cleanup_task_status;
ALTER TABLE cleanup_tasks ALTER COLUMN task_type TYPE cleanup_task_type USING task_type::cleanup_task_type;

-- 5. Re-add defaults
ALTER TABLE cleanup_tasks ALTER COLUMN status SET DEFAULT 'created'::cleanup_task_status;
ALTER TABLE cleanup_tasks ALTER COLUMN task_type SET DEFAULT 'Cleanup'::cleanup_task_type;
