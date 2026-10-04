-- 1. Create ENUMs
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'audit_log_action_type') THEN
        CREATE TYPE audit_log_action_type AS ENUM (
            'user_created', 'login', 'logout', 'password_change', 'password_reset', 'profile_update', 'account_deletion'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'response_log_action_type') THEN
        CREATE TYPE response_log_action_type AS ENUM (
            'citizen_close', 'manual_note', 'lifecycle_stage_update', 'status_update', 'assigned', 'unassigned'
        );
    END IF;
END
$$;

-- 2. Drop constraints
-- (None were present)

-- 3. Drop defaults
ALTER TABLE audit_logs ALTER COLUMN action_type DROP DEFAULT;
ALTER TABLE response_log ALTER COLUMN action_type DROP DEFAULT;

-- 4. Alter columns
ALTER TABLE audit_logs ALTER COLUMN action_type TYPE audit_log_action_type USING action_type::audit_log_action_type;
ALTER TABLE response_log ALTER COLUMN action_type TYPE response_log_action_type USING action_type::response_log_action_type;
