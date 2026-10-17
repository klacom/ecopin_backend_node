-- 20261016120000_add_photo_location_verification.sql
-- Adds photo location verification telemetry and trust status to reports table

ALTER TABLE public.reports
ADD COLUMN IF NOT EXISTS photo_lat double precision,
ADD COLUMN IF NOT EXISTS photo_lng double precision,
ADD COLUMN IF NOT EXISTS photo_accuracy double precision,
ADD COLUMN IF NOT EXISTS photo_captured_at timestamptz,
ADD COLUMN IF NOT EXISTS photo_source text,
ADD COLUMN IF NOT EXISTS is_mocked boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS location_verification_status text DEFAULT 'unverified_gallery',
ADD COLUMN IF NOT EXISTS photo_distance_meters double precision;

COMMENT ON COLUMN public.reports.location_verification_status IS 
'Photo location verification status: verified_on_site, nearby_approximate, location_mismatch, or unverified_gallery';

-- Drop and recreate reports_view to include photo verification columns
DROP VIEW IF EXISTS public.reports_view;

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
  photo_lat,
  photo_lng,
  photo_accuracy,
  photo_captured_at,
  photo_source,
  is_mocked,
  location_verification_status,
  photo_distance_meters
FROM
  public.reports;

GRANT SELECT ON public.reports_view TO authenticated, service_role;
