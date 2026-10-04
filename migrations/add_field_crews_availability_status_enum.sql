-- 1. Create ENUM
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crew_availability_status') THEN
        CREATE TYPE crew_availability_status AS ENUM (
            'available', 'on_route', 'off_shift', 'disabled'
        );
    END IF;
END
$$;

-- 2. Drop the old CHECK constraint before altering the column
ALTER TABLE field_crews DROP CONSTRAINT IF EXISTS field_crews_availability_status_check;

-- 3. Drop default so we can alter the column
ALTER TABLE field_crews ALTER COLUMN availability_status DROP DEFAULT;

-- 4. Alter the field_crews table
ALTER TABLE field_crews ALTER COLUMN availability_status TYPE crew_availability_status USING availability_status::crew_availability_status;

-- 5. Re-add default
ALTER TABLE field_crews ALTER COLUMN availability_status SET DEFAULT 'available'::crew_availability_status;
