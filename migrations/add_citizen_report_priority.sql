-- PDT-01: requested urgency is independent of calculated severity and dispatch.
-- Apply before deploying the API/mobile update. Existing reports remain unspecified.
BEGIN;
ALTER TABLE public.reports
  ADD COLUMN citizen_priority text,
  ADD COLUMN priority_reason text,
  ADD COLUMN priority_explanation text,
  ADD CONSTRAINT reports_citizen_priority_check CHECK (
    (citizen_priority IS NULL AND priority_reason IS NULL AND priority_explanation IS NULL)
    OR (citizen_priority IS NOT NULL AND citizen_priority = 'non_urgent' AND priority_reason IS NULL AND priority_explanation IS NULL)
    OR (citizen_priority IS NOT NULL AND citizen_priority = 'urgent' AND priority_reason IS NOT NULL
      AND priority_reason IN ('community_event', 'school_hospital_zone', 'severe_obstruction', 'public_health_hazard')
      AND (priority_explanation IS NULL OR char_length(priority_explanation) <= 1000))
  );
COMMENT ON COLUMN public.reports.citizen_priority IS
  'Citizen request only. Urgent requires officer verification; does not approve or escalate dispatch.';
COMMIT;
