-- 20261026160500_add_report_address_and_barangay_resolution.sql
-- Add explicit address and barangay columns to reports and expose via public/staff views.
-- Provides fallback and polygon-based administrative resolution.

BEGIN;

SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';

-- 1. Add columns to reports table
ALTER TABLE public.reports
  ADD COLUMN IF NOT EXISTS street_address text,
  ADD COLUMN IF NOT EXISTS barangay text,
  ADD COLUMN IF NOT EXISTS city text DEFAULT 'Pasig City';

-- 2. Grant permissions on new columns to ecopin_public_map_reader
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ecopin_public_map_reader') THEN
    GRANT SELECT (street_address, barangay, city) ON public.reports TO ecopin_public_map_reader;
  END IF;
END $$;

-- 3. Create or replace spatial barangay resolution function
CREATE OR REPLACE FUNCTION public.get_report_barangay(lat double precision, lng double precision)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  found_barangay text;
BEGIN
  IF lat IS NULL OR lng IS NULL THEN
    RETURN 'Pasig City';
  END IF;

  -- 1. Check official polygon containment from spatial_zones if polygon data exists
  SELECT zone_name INTO found_barangay
  FROM public.spatial_zones
  WHERE zone_type = 'barangay'
    AND boundary IS NOT NULL
    AND extensions.ST_Contains(boundary, extensions.ST_SetSRID(extensions.ST_Point(lng, lat), 4326))
  LIMIT 1;

  IF found_barangay IS NOT NULL THEN
    RETURN found_barangay;
  END IF;

  -- 2. Fallback to nearest official Pasig City centroid
  SELECT name INTO found_barangay
  FROM (
    VALUES
      ('Bagong Ilog', 14.5682, 121.0660),
      ('Bagong Katipunan', 14.5574, 121.0776),
      ('Bambang', 14.5539, 121.0805),
      ('Buting', 14.5520, 121.0689),
      ('Caniogan', 14.5677, 121.0801),
      ('Dela Paz', 14.6133, 121.0969),
      ('Kalawaan', 14.5442, 121.0837),
      ('Kapasigan', 14.5595, 121.0805),
      ('Kapitolyo', 14.5714, 121.0592),
      ('Malinao', 14.5552, 121.0754),
      ('Manggahan', 14.5996, 121.0967),
      ('Maybunga', 14.5775, 121.0965),
      ('Oranbo', 14.5771, 121.0635),
      ('Palatiw', 14.5617, 121.0872),
      ('Pinagbuhatan', 14.5486, 121.0961),
      ('Pineda', 14.5646, 121.0543),
      ('Rosario', 14.5875, 121.0920),
      ('Sagad', 14.5647, 121.0789),
      ('San Antonio', 14.5815, 121.0645),
      ('San Joaquin', 14.5502, 121.0736),
      ('San Jose', 14.5546, 121.0747),
      ('San Nicolas', 14.5541, 121.0784),
      ('Santa Cruz', 14.5583, 121.0742),
      ('Santa Lucia', 14.5888, 121.1098),
      ('Santa Rosa', 14.5562, 121.0789),
      ('Santolan', 14.6139, 121.0864),
      ('Santo Tomas', 14.5517, 121.0818),
      ('Sumilang', 14.5529, 121.0769),
      ('Ugong', 14.5898, 121.0754),
      ('San Miguel', 14.5607, 121.0851)
  ) AS b(name, b_lat, b_lng)
  ORDER BY extensions.ST_Distance(
    extensions.ST_SetSRID(extensions.ST_Point(lng, lat), 4326)::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_Point(b.b_lng, b.b_lat), 4326)::extensions.geography
  ) ASC
  LIMIT 1;

  RETURN COALESCE(found_barangay, 'Pasig City');
END;
$$;

-- 4. Recreate reports_view with address and barangay
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
  photo_distance_meters,
  street_address,
  barangay,
  city
FROM
  public.reports;

GRANT SELECT ON public.reports_view TO authenticated, service_role;

-- 5. Recreate public_reports with address and barangay
DROP VIEW IF EXISTS public.public_reports;

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
  CASE WHEN on_private_property THEN 'approximate'::text ELSE 'exact'::text END AS location_precision,
  street_address,
  barangay,
  city
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
