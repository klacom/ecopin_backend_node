-- Migration: Add rejected_at and rejection_reason to reports
-- Description:
--   rejected_at  — timestamp written when a report's validation_status is set to
--                  'rejected', either by the AI pipeline or by an officer/admin.
--   rejection_reason — human-readable reason for the rejection, already written by
--                      the AI pipeline but previously not included in reports_view.
--
-- Both columns are needed for:
--   1. The Citizen-facing "Rejected on: <date>" display in report details.
--   2. The 24-hour rejected-report visibility window in My Reports.
--   3. Surface-level feedback so the Citizen understands why the report was rejected.

-- Step 1: Add columns to the reports table (idempotent).
ALTER TABLE reports
  ADD COLUMN IF NOT EXISTS rejected_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS rejection_reason TEXT;

-- Step 2: Recreate reports_view to include the new columns.
-- Drop and recreate because PostgreSQL does not support adding columns to a view
-- via ALTER VIEW; the view must be recreated.
DROP VIEW IF EXISTS reports_view;

CREATE VIEW public.reports_view AS
SELECT
  id,
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
  is_overdue,
  severity_score,
  urgency_score,
  ra9003_category,
  ml_predicted_class,
  ml_confidence,
  ml_probabilities,
  rejection_reason,
  rejected_at
FROM
  reports;
