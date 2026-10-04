-- Create the ENUM type
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'dispatch_plan_status') THEN
        CREATE TYPE dispatch_plan_status AS ENUM ('draft', 'approved', 'discarded');
    END IF;
END
$$;

-- Drop the old CHECK constraint before altering the column
ALTER TABLE dispatch_plans DROP CONSTRAINT IF EXISTS dispatch_plans_status_check;

-- Drop default so we can alter the column
ALTER TABLE dispatch_plans ALTER COLUMN status DROP DEFAULT;

-- Alter the dispatch_plans table
ALTER TABLE dispatch_plans ALTER COLUMN status TYPE dispatch_plan_status USING status::dispatch_plan_status;

-- Re-add default
ALTER TABLE dispatch_plans ALTER COLUMN status SET DEFAULT 'draft'::dispatch_plan_status;
