-- Migration: 20261012120000_harden_definer_routines_search_path_and_parameter_bounds.sql
-- Description: Hardens remaining security definer functions with safe empty search_path,
--              enforces spatial and temporal parameter bounds on count_recent_nearby_reports,
--              restricts nextval to verified public sequences, and hardens signup role defaults.

SET LOCAL lock_timeout = '2s';

-- 1. Hardened handle_new_user with empty search_path and immutable citizen default
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, role, is_email_verified)
  VALUES (new.id, 'citizen'::public.role, false)
  ON CONFLICT (id) DO NOTHING;
  RETURN new;
END;
$$;

-- 2. Hardened handle_report_status_change with empty search_path and qualified notifications
CREATE OR REPLACE FUNCTION public.handle_report_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (old.status IS DISTINCT FROM new.status) OR (old.validation_status IS DISTINCT FROM new.validation_status) THEN
    INSERT INTO public.notifications (user_id, report_id, type, title, body)
    VALUES (
      new.user_id,
      new.id,
      'lifecycle_update'::public.notification_type,
      CASE 
        WHEN old.status IS DISTINCT FROM new.status THEN 'Report Status Updated'
        WHEN old.validation_status IS DISTINCT FROM new.validation_status THEN 'Report Validation Updated'
        ELSE 'Report Updated'
      END,
      CASE 
        WHEN old.status IS DISTINCT FROM new.status THEN 'Your report "' || coalesce(new.title, '') || '" is now ' || new.status::text || '.'
        WHEN old.validation_status IS DISTINCT FROM new.validation_status THEN 'Your report "' || coalesce(new.title, '') || '" validation status is now ' || new.validation_status::text || '.'
        ELSE 'Your report "' || coalesce(new.title, '') || '" has been updated.'
      END
    );
  END IF;
  RETURN new;
END;
$$;

-- 3. Hardened nextval wrapper: empty search_path, restricted to public sequences, service-only ACL
CREATE OR REPLACE FUNCTION public.nextval(seq_name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_seq regclass;
BEGIN
  IF seq_name IS NULL OR pg_catalog.btrim(seq_name) = '' THEN
    RAISE EXCEPTION 'Sequence name cannot be empty' USING ERRCODE = '22023';
  END IF;

  SELECT c.oid::regclass INTO v_seq
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'S'
    AND n.nspname = 'public'
    AND c.relname = pg_catalog.btrim(seq_name);

  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'Sequence "%" not found in schema public', seq_name USING ERRCODE = '42P01';
  END IF;

  RETURN pg_catalog.nextval(v_seq);
END;
$$;

REVOKE ALL ON FUNCTION public.nextval(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nextval(text) TO postgres, service_role;

-- 4. Hardened count_recent_nearby_reports: empty search_path, strict bounds, service-only ACL
CREATE OR REPLACE FUNCTION public.count_recent_nearby_reports(
  p_lon double precision,
  p_lat double precision,
  p_radius_meters double precision,
  p_days integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  IF p_lon IS NULL OR p_lon < -180.0 OR p_lon > 180.0 THEN
    RAISE EXCEPTION 'p_lon must be between -180 and 180' USING ERRCODE = '22023';
  END IF;
  IF p_lat IS NULL OR p_lat < -90.0 OR p_lat > 90.0 THEN
    RAISE EXCEPTION 'p_lat must be between -90 and 90' USING ERRCODE = '22023';
  END IF;

  IF p_radius_meters IS NULL OR p_radius_meters <= 0.0 OR p_radius_meters > 50000.0 THEN
    RAISE EXCEPTION 'p_radius_meters must be between 1 and 50000 meters' USING ERRCODE = '22023';
  END IF;
  IF p_days IS NULL OR p_days < 1 OR p_days > 365 THEN
    RAISE EXCEPTION 'p_days must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  SELECT pg_catalog.count(*)::integer INTO v_count
  FROM public.reports
  WHERE extensions.ST_DWithin(
    location::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_MakePoint(p_lon, p_lat), 4326)::extensions.geography,
    p_radius_meters
  )
  AND created_at >= (pg_catalog.now() - (p_days * '1 day'::interval));

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.count_recent_nearby_reports(double precision, double precision, double precision, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.count_recent_nearby_reports(double precision, double precision, double precision, integer) TO postgres, service_role;
