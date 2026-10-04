-- Create the ENUM type
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_status') THEN
        CREATE TYPE report_status AS ENUM (
            'unresolved', 
            'in_progress', 
            'resolved', 
            'pending_owner_consent', 
            'waiting_for_feedback', 
            'closed', 
            'completed', 
            'rejected'
        );
    END IF;
END
$$;

-- Drop the view that depends on status
DROP VIEW IF EXISTS reports_view;

-- Drop default so we can alter the column
ALTER TABLE reports ALTER COLUMN status DROP DEFAULT;

-- Alter the reports table
ALTER TABLE reports ALTER COLUMN status TYPE report_status USING status::report_status;

-- Re-add default
ALTER TABLE reports ALTER COLUMN status SET DEFAULT 'unresolved'::report_status;

-- Recreate the view
-- Note: status is explicitly cast to text (status::text) for the array comparison 
-- to avoid type mismatch errors between the new ENUM and text arrays.
CREATE VIEW reports_view AS 
 SELECT id,
    user_id,
    title,
    description,
    issue_type,
    location,
    validation_status,
    status,
    cluster_id,
    created_at,
    updated_at,
    notes,
    before_photo_url,
    after_photo_url,
    on_private_property,
    property_owner_consent_status,
    stage,
    satisfaction_rating,
    lgu_resolved_at,
    citizen_closed_at,
    (status::text <> ALL (ARRAY['resolved'::text, 'closed'::text, 'completed'::text, 'rejected'::text])) AND CURRENT_TIMESTAMP > deadline_at AS is_overdue,
    severity_score,
    urgency_score,
    ra9003_category,
    ml_predicted_class,
    ml_confidence,
    ml_probabilities,
    deadline_at
   FROM reports;
