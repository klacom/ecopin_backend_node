-- Rollback 20261026160500_add_report_address_and_barangay_resolution.sql

BEGIN;

SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';

DROP VIEW IF EXISTS public.public_reports;
DROP VIEW IF EXISTS public.reports_view;

DROP FUNCTION IF EXISTS public.get_report_barangay(double precision, double precision);

ALTER TABLE public.reports
  DROP COLUMN IF EXISTS street_address,
  DROP COLUMN IF EXISTS barangay,
  DROP COLUMN IF EXISTS city;

-- Recreate previous reports_view without address columns
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

-- Recreate previous public_reports view without address columns
CREATE VIEW public.public_reports WITH (security_barrier=true, security_invoker=false) AS
SELECT
  id,
  title,
  description,
  issue_type,
  status,
  cluster_id,
  created_at,
  updated_at,
  stage,
  is_overdue,
  severity_score,
  severity_level,
  lifecycle_state,
  breached_at,
  validation_status,
  extensions.st_asgeojson(
    CASE WHEN on_private_property THEN
      extensions.st_setsrid(
        extensions.st_makepoint(
          round(extensions.st_x(location::extensions.geometry)::numeric, 3)::double precision,
          round(extensions.st_y(location::extensions.geometry)::numeric, 3)::double precision
        ), 4326
      )
    ELSE location::extensions.geometry END,
    9, 0
  )::jsonb AS location,
  CASE WHEN on_private_property THEN round(extensions.st_y(location::extensions.geometry)::numeric, 3)::double precision ELSE extensions.st_y(location::extensions.geometry) END AS latitude,
  CASE WHEN on_private_property THEN round(extensions.st_x(location::extensions.geometry)::numeric, 3)::double precision ELSE extensions.st_x(location::extensions.geometry) END AS longitude,
  CASE WHEN on_private_property THEN 'approximate'::text ELSE 'exact'::text END AS location_precision
FROM public.reports
WHERE validation_status = 'approved' AND status <> 'rejected'
  AND (on_private_property IS FALSE OR (on_private_property IS TRUE AND property_owner_consent_status = 'obtained'));

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ecopin_public_map_reader') THEN
    GRANT CREATE ON SCHEMA public TO ecopin_public_map_reader;
    ALTER VIEW public.public_reports OWNER TO ecopin_public_map_reader;
    REVOKE CREATE ON SCHEMA public FROM ecopin_public_map_reader;
  END IF;
END $$;

REVOKE ALL ON public.public_reports FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.public_reports TO anon, authenticated, service_role;

COMMIT;
