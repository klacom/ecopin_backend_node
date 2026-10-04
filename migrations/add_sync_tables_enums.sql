-- 1. Create ENUMs
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'sync_entity_type') THEN
        CREATE TYPE sync_entity_type AS ENUM (
            'report', 'task', 'cluster', 'dispatch_plan'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'sync_operation_type') THEN
        CREATE TYPE sync_operation_type AS ENUM (
            'fc.report.update_status', 
            'fc.report.update_lifecycle_stage', 
            'fc.report.update_validation', 
            'fc.report.update_details', 
            'fc.note.add', 
            'fc.task.mark_complete', 
            'fc.photo.upload_before', 
            'fc.photo.upload_after', 
            'fc.photo.delete', 
            'task_update', 
            'report_create', 
            'report_update'
        );
    END IF;
END
$$;

-- 2. Drop constraints
-- (None exist on these columns)

-- 3. Drop defaults
ALTER TABLE fc_operation_log ALTER COLUMN operation_type DROP DEFAULT;
ALTER TABLE fc_operation_log ALTER COLUMN entity_type DROP DEFAULT;

ALTER TABLE fc_conflict_audit ALTER COLUMN operation_type DROP DEFAULT;
ALTER TABLE fc_conflict_audit ALTER COLUMN entity_type DROP DEFAULT;

ALTER TABLE sync_conflicts ALTER COLUMN operation_type DROP DEFAULT;
-- Note: sync_conflicts does not have an entity_type column

-- 4. Alter columns for entity_type
ALTER TABLE fc_operation_log ALTER COLUMN entity_type TYPE sync_entity_type USING entity_type::sync_entity_type;
ALTER TABLE fc_conflict_audit ALTER COLUMN entity_type TYPE sync_entity_type USING entity_type::sync_entity_type;

-- 5. Alter columns for operation_type
ALTER TABLE fc_operation_log ALTER COLUMN operation_type TYPE sync_operation_type USING operation_type::sync_operation_type;
ALTER TABLE fc_conflict_audit ALTER COLUMN operation_type TYPE sync_operation_type USING operation_type::sync_operation_type;
ALTER TABLE sync_conflicts ALTER COLUMN operation_type TYPE sync_operation_type USING operation_type::sync_operation_type;

-- 6. Re-add defaults
-- (None existed)
