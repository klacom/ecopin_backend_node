-- Rollback migration: 20261012120000_harden_definer_routines_search_path_and_parameter_bounds.sql

SET LOCAL lock_timeout = '2s';

-- 1. Revert handle_new_user
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.profiles (id, role, is_email_verified)
  VALUES (new.id, 'citizen', false);
  RETURN new;
END;
$$;

-- 2. Revert handle_report_status_change
CREATE OR REPLACE FUNCTION public.handle_report_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF (old.status IS DISTINCT FROM new.status) OR (old.validation_status IS DISTINCT FROM new.validation_status) THEN
    INSERT INTO public.notifications (user_id, report_id, title, body)
    VALUES (
      new.user_id,
      new.id,
      CASE 
        WHEN old.status IS DISTINCT FROM new.status THEN 'Report Status Updated'
        WHEN old.validation_status IS DISTINCT FROM new.validation_status THEN 'Report Validation Updated'
        ELSE 'Report Updated'
      END,
      CASE 
        WHEN old.status IS DISTINCT FROM new.status THEN 'Your report "' || new.title || '" is now ' || new.status || '.'
        WHEN old.validation_status IS DISTINCT FROM new.validation_status THEN 'Your report "' || new.title || '" validation status is now ' || new.validation_status || '.'
        ELSE 'Your report "' || new.title || '" has been updated.'
      END
    );
  END IF;
  RETURN new;
END;
$$;

-- 3. Revert nextval
CREATE OR REPLACE FUNCTION public.nextval(seq_name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN nextval(seq_name::regclass);
END;
$$;

REVOKE ALL ON FUNCTION public.nextval(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nextval(text) TO postgres, service_role;

-- 4. Revert count_recent_nearby_reports
CREATE OR REPLACE FUNCTION public.count_recent_nearby_reports(
  p_lon double precision,
  p_lat double precision,
  p_radius_meters double precision,
  p_days integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.reports
  WHERE extensions.ST_DWithin(
    location::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_MakePoint(p_lon, p_lat), 4326)::extensions.geography,
    p_radius_meters
  )
  AND created_at >= NOW() - (p_days || ' days')::INTERVAL;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.count_recent_nearby_reports(double precision, double precision, double precision, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.count_recent_nearby_reports(double precision, double precision, double precision, integer) TO postgres, service_role;
