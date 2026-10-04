-- Create the ENUM type (Already created in db, but here for completeness)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_issue_type') THEN
        CREATE TYPE report_issue_type AS ENUM ('waste', 'flooding', 'pollution', 'infrastructure', 'illegal_logging', 'pending', 'others');
    END IF;
END
$$;

-- Note: The duplicate values have already been cleaned up directly in the database.

-- Drop the view that depends on issue_type
DROP VIEW IF EXISTS reports_view;

-- Alter the reports table
ALTER TABLE reports ALTER COLUMN issue_type TYPE report_issue_type USING issue_type::report_issue_type;

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
