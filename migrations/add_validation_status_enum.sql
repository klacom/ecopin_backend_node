-- Consolidate duplicate/similar values into 'approved'
UPDATE reports 
SET validation_status = 'approved' 
WHERE validation_status IN ('valid', 'validated', 'automatically_valid');

-- Create the ENUM type
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_validation_status') THEN
        CREATE TYPE report_validation_status AS ENUM ('pending', 'pending_ai_validation', 'manual_review', 'approved', 'rejected');
    END IF;
END
$$;

-- Drop the view that depends on validation_status
DROP VIEW IF EXISTS reports_view;

-- Drop default so we can alter the column
ALTER TABLE reports ALTER COLUMN validation_status DROP DEFAULT;

-- Alter the reports table
ALTER TABLE reports ALTER COLUMN validation_status TYPE report_validation_status USING validation_status::report_validation_status;

-- Re-add default
ALTER TABLE reports ALTER COLUMN validation_status SET DEFAULT 'pending'::report_validation_status;

-- Recreate the view
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
    (status <> ALL (ARRAY['resolved'::text, 'closed'::text, 'completed'::text, 'rejected'::text])) AND CURRENT_TIMESTAMP > deadline_at AS is_overdue,
    severity_score,
    urgency_score,
    ra9003_category,
    ml_predicted_class,
    ml_confidence,
    ml_probabilities,
    deadline_at
   FROM reports;
