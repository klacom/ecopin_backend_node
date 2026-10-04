-- 1. Create ENUMs
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'consent_status') THEN
        CREATE TYPE consent_status AS ENUM (
            'not_required', 'pending', 'obtained', 'denied'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_severity_level') THEN
        CREATE TYPE report_severity_level AS ENUM (
            'Low', 'Medium', 'High'
        );
    END IF;
END
$$;

-- 2. Drop the view
DROP VIEW IF EXISTS reports_view;

-- 3. Drop constraints
ALTER TABLE reports DROP CONSTRAINT IF EXISTS reports_property_owner_consent_status_check;

-- 4. Drop defaults
ALTER TABLE reports ALTER COLUMN property_owner_consent_status DROP DEFAULT;

-- 5. Alter columns
ALTER TABLE reports ALTER COLUMN property_owner_consent_status TYPE consent_status USING property_owner_consent_status::consent_status;
ALTER TABLE reports ALTER COLUMN severity_level TYPE report_severity_level USING severity_level::report_severity_level;

-- 6. Re-add defaults
ALTER TABLE reports ALTER COLUMN property_owner_consent_status SET DEFAULT 'not_required'::consent_status;

-- 7. Recreate view
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
