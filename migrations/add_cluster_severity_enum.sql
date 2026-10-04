-- Create the ENUM type
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cluster_severity') THEN
        CREATE TYPE cluster_severity AS ENUM ('low', 'medium', 'high');
    END IF;
END
$$;

-- Drop the old CHECK constraint before altering the column
ALTER TABLE clusters DROP CONSTRAINT IF EXISTS clusters_severity_check;

-- Alter the clusters table
ALTER TABLE clusters ALTER COLUMN severity TYPE cluster_severity USING severity::cluster_severity;
