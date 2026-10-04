-- Create the ENUM type
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cluster_status') THEN
        CREATE TYPE cluster_status AS ENUM (
            'new',
            'unresolved',
            'prioritized', 
            'queued',
            'scheduled', 
            'in_progress', 
            'resolved', 
            'needs_verification',
            'monitoring',
            'deferred',
            'escalated',
            'completed', 
            'closed'
        );
    END IF;
END
$$;

-- Drop the old CHECK constraint before altering the column
ALTER TABLE clusters DROP CONSTRAINT IF EXISTS clusters_status_check;

-- Drop default so we can alter the column
ALTER TABLE clusters ALTER COLUMN status DROP DEFAULT;

-- Alter the clusters table
ALTER TABLE clusters ALTER COLUMN status TYPE cluster_status USING status::cluster_status;

-- Re-add default
ALTER TABLE clusters ALTER COLUMN status SET DEFAULT 'unresolved'::cluster_status;
