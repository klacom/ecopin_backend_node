-- Add rejection reason and timestamp fields to reports table
ALTER TABLE reports
ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
ADD COLUMN IF NOT EXISTS rejected_at TIMESTAMPTZ;

-- Update reports_view to include the new columns
DROP VIEW IF EXISTS reports_view;
CREATE OR REPLACE VIEW reports_view AS
SELECT 
    r.*,
    p.full_name,
    p.phone,
    p.address AS profile_address
FROM reports r
LEFT JOIN profiles p ON r.user_id = p.id;
