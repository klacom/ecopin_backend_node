-- Update reports_view to include satisfaction_rating and related columns
DROP VIEW IF EXISTS reports_view;
CREATE OR REPLACE VIEW reports_view AS
SELECT 
    r.*,
    p.full_name,
    p.phone,
    p.address AS profile_address
FROM reports r
LEFT JOIN profiles p ON r.user_id = p.id;
