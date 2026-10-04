-- 1. Create ENUMs
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'manual_review_status') THEN
        CREATE TYPE manual_review_status AS ENUM (
            'pending', 'in_review', 'reviewed'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'manual_review_type') THEN
        CREATE TYPE manual_review_type AS ENUM (
            'severe_violation', 'report_flag', 'user_appeal', 'other'
        );
    END IF;
END
$$;

-- 2. Drop defaults
ALTER TABLE manual_review_queue ALTER COLUMN status DROP DEFAULT;

-- 3. Alter columns
ALTER TABLE manual_review_queue ALTER COLUMN status TYPE manual_review_status USING status::manual_review_status;
ALTER TABLE manual_review_queue ALTER COLUMN review_type TYPE manual_review_type USING review_type::manual_review_type;

-- 4. Re-add default
ALTER TABLE manual_review_queue ALTER COLUMN status SET DEFAULT 'pending'::manual_review_status;
