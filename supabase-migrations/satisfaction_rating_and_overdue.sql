-- Update reports table with new fields for satisfaction rating and timestamps
ALTER TABLE reports
ADD COLUMN IF NOT EXISTS satisfaction_rating INT CHECK (satisfaction_rating >= 1 AND satisfaction_rating <= 5),
ADD COLUMN IF NOT EXISTS lgu_resolved_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS citizen_closed_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS is_overdue BOOLEAN DEFAULT FALSE;

-- Create a function to check and update overdue reports
CREATE OR REPLACE FUNCTION check_overdue_reports()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Update reports that are still unresolved at end of operational day (18:00 local time)
    UPDATE reports
    SET is_overdue = TRUE
    WHERE status IN ('unresolved', 'in_progress', 'pending_owner_consent')
      AND DATE(created_at) = CURRENT_DATE
      AND EXTRACT(HOUR FROM CURRENT_TIME) >= 18
      AND is_overdue = FALSE;
END;
$$;

-- Create a cron job to run the check at 18:00 every day (Supabase cron syntax)
-- Note: Requires pg_cron extension enabled
-- SELECT cron.schedule(
--     'check-overdue-reports',
--     '0 18 * * *',  -- Run daily at 18:00
--     'SELECT check_overdue_reports();'
-- );

-- Optional: Update reports_view to include new columns
-- DROP VIEW IF EXISTS reports_view;
-- CREATE OR REPLACE VIEW reports_view AS
-- SELECT 
--     r.*,
--     p.full_name,
--     p.phone,
--     p.address AS profile_address
-- FROM reports r
-- LEFT JOIN profiles p ON r.user_id = p.id;

