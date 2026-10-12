BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';

CREATE TEMP TABLE definer_test_results(test text, status text) ON COMMIT DROP;
GRANT INSERT, SELECT ON definer_test_results TO service_role, anon, authenticated;

CREATE FUNCTION pg_temp.definer_assert(label text, condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN 
  INSERT INTO definer_test_results VALUES(label, CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END); 
END $$;

DO $$
DECLARE
  v_count integer;
  v_val bigint;
  test_user_id uuid := gen_random_uuid();
  test_report_id uuid := gen_random_uuid();
  notif_row record;
  user_profile_role text;
  non_empty_count integer;
BEGIN
  -- ====================================================================
  -- 1. count_recent_nearby_reports: Valid Execution & Bounds Checks
  -- ====================================================================
  -- Valid call as postgres / service_role
  SELECT public.count_recent_nearby_reports(121.05, 14.55, 1000.0, 30) INTO v_count;
  PERFORM pg_temp.definer_assert('count_recent_nearby_reports valid call succeeds', v_count >= 0);

  -- Lon > 180 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(181.0, 14.55, 1000.0, 30);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lon > 180', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lon > 180', true);
  END;

  -- Lon < -180 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(-181.0, 14.55, 1000.0, 30);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lon < -180', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lon < -180', true);
  END;

  -- Lat > 90 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, 91.0, 1000.0, 30);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lat > 90', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lat > 90', true);
  END;

  -- Lat < -90 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, -91.0, 1000.0, 30);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lat < -90', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects lat < -90', true);
  END;

  -- Radius <= 0 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, 14.55, 0.0, 30);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects radius <= 0', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects radius <= 0', true);
  END;

  -- Radius > 50000 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, 14.55, 50001.0, 30);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects radius > 50000', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects radius > 50000', true);
  END;

  -- Days < 1 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, 14.55, 1000.0, 0);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects days < 1', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects days < 1', true);
  END;

  -- Days > 365 rejected
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, 14.55, 1000.0, 366);
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects days > 365', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('count_recent_nearby_reports rejects days > 365', true);
  END;

  -- ====================================================================
  -- 2. count_recent_nearby_reports: Client Execution Denied (42501)
  -- ====================================================================
  PERFORM set_config('role', 'anon', true);
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, 14.55, 1000.0, 30);
    PERFORM pg_temp.definer_assert('anon execution of count_recent_nearby_reports denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.definer_assert('anon execution of count_recent_nearby_reports denied', true);
  END;

  PERFORM set_config('role', 'authenticated', true);
  BEGIN
    PERFORM public.count_recent_nearby_reports(121.05, 14.55, 1000.0, 30);
    PERFORM pg_temp.definer_assert('authenticated execution of count_recent_nearby_reports denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.definer_assert('authenticated execution of count_recent_nearby_reports denied', true);
  END;

  PERFORM set_config('role', 'postgres', true);

  -- ====================================================================
  -- 3. nextval: Valid Execution, Parameter Validation & ACLs
  -- ====================================================================
  -- Valid call on public sequence
  SELECT public.nextval('sweeper_audit_log_id_seq') INTO v_val;
  PERFORM pg_temp.definer_assert('nextval valid sequence call succeeds', v_val > 0);

  -- Empty sequence name rejected
  BEGIN
    PERFORM public.nextval('   ');
    PERFORM pg_temp.definer_assert('nextval rejects empty sequence name', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.definer_assert('nextval rejects empty sequence name', true);
  END;

  -- Non-existent sequence rejected
  BEGIN
    PERFORM public.nextval('non_existent_seq_123');
    PERFORM pg_temp.definer_assert('nextval rejects non-existent sequence', false);
  EXCEPTION WHEN sqlstate '42P01' THEN
    PERFORM pg_temp.definer_assert('nextval rejects non-existent sequence', true);
  END;

  -- Non-public sequence access blocked (e.g. pg_toast or other catalog)
  BEGIN
    PERFORM public.nextval('pg_class');
    PERFORM pg_temp.definer_assert('nextval rejects non-sequence catalog relations', false);
  EXCEPTION WHEN sqlstate '42P01' THEN
    PERFORM pg_temp.definer_assert('nextval rejects non-sequence catalog relations', true);
  END;

  -- Client execution denied
  PERFORM set_config('role', 'anon', true);
  BEGIN
    PERFORM public.nextval('sweeper_audit_log_id_seq');
    PERFORM pg_temp.definer_assert('anon execution of nextval denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.definer_assert('anon execution of nextval denied', true);
  END;

  PERFORM set_config('role', 'authenticated', true);
  BEGIN
    PERFORM public.nextval('sweeper_audit_log_id_seq');
    PERFORM pg_temp.definer_assert('authenticated execution of nextval denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.definer_assert('authenticated execution of nextval denied', true);
  END;

  PERFORM set_config('role', 'postgres', true);

  -- ====================================================================
  -- 4. handle_new_user: Forged Role Metadata Ignored, Defaults to Citizen
  -- ====================================================================
  -- Simulate signup with attacker metadata attempting role escalation
  INSERT INTO auth.users (id, email, raw_user_meta_data)
  VALUES (test_user_id, 'attacker@example.invalid', '{"role": "admin", "is_admin": true}'::jsonb);

  SELECT role::text INTO user_profile_role FROM public.profiles WHERE id = test_user_id;
  PERFORM pg_temp.definer_assert('handle_new_user assigns immutable citizen role', user_profile_role = 'citizen');

  -- ====================================================================
  -- 5. handle_report_status_change: Status and Validation Transitions
  -- ====================================================================
  INSERT INTO public.reports (id, user_id, title, description, issue_type, location, status, validation_status)
  VALUES (test_report_id, test_user_id, 'Definer Test Waste', 'Desc', 'waste', extensions.ST_SetSRID(extensions.ST_MakePoint(121.05, 14.55), 4326), 'unresolved', 'pending');

  -- Trigger status update
  UPDATE public.reports SET status = 'in_progress' WHERE id = test_report_id;
  PERFORM pg_temp.definer_assert('handle_report_status_change generates status notification',
    EXISTS(SELECT 1 FROM public.notifications WHERE report_id = test_report_id AND title = 'Report Status Updated'));

  -- Trigger validation status update
  UPDATE public.reports SET validation_status = 'approved' WHERE id = test_report_id;
  PERFORM pg_temp.definer_assert('handle_report_status_change generates validation notification',
    EXISTS(SELECT 1 FROM public.notifications WHERE report_id = test_report_id AND title = 'Report Validation Updated'));

  -- ====================================================================
  -- 6. Verify Zero Non-Empty Search Path Definers
  -- ====================================================================
  SELECT count(*) INTO non_empty_count
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname IN ('public', 'workflow_private')
    AND p.prosecdef = true
    AND (
      p.proconfig IS NULL 
      OR NOT ('search_path=""' = ANY(p.proconfig) OR 'search_path=' = ANY(p.proconfig))
    );

  PERFORM pg_temp.definer_assert('All security definer functions have empty search path', non_empty_count = 0);

END $$;

SELECT * FROM definer_test_results ORDER BY test;
ROLLBACK;
