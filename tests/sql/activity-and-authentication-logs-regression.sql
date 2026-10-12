BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';

CREATE TEMP TABLE log_audit_results (
  test text,
  status text,
  detail text
) ON COMMIT DROP;
GRANT SELECT, INSERT ON log_audit_results TO authenticated, anon, service_role;

DO $$
DECLARE
  v_admin uuid;
  v_officer uuid;
  v_crew uuid;
  v_citizen uuid;
  v_rid uuid := gen_random_uuid();
  v_count integer;
  v_auth_count integer;
  v_note_id uuid;
BEGIN
  SELECT id INTO v_admin FROM public.profiles WHERE role::text = 'admin' LIMIT 1;
  SELECT id INTO v_officer FROM public.profiles WHERE role::text = 'officer' LIMIT 1;
  SELECT id INTO v_crew FROM public.profiles WHERE role::text = 'field_crew' LIMIT 1;
  SELECT id INTO v_citizen FROM public.profiles WHERE role::text = 'citizen' LIMIT 1;

  -- Setup fixture report for response_log
  INSERT INTO public.reports (id, user_id, title, issue_type, location, severity_score, validation_status)
  VALUES (v_rid, v_citizen, 'Log Audit Test Report', 'waste', extensions.st_setsrid(extensions.st_makepoint(122, 15), 4326), 2, 'approved');

  -- Insert fixture system log (authentication event) as service_role
  INSERT INTO public.system_logs (user_id, action_type, action_details, ip_address, user_agent)
  VALUES (v_admin, 'login'::public.audit_log_action_type, 'Successful admin login', '127.0.0.1', 'AuditRunner/1.0');

  -- Insert fixture response log (report activity event) as officer
  INSERT INTO public.audit_logs (report_id, user_id, action_type, action_details)
  VALUES (v_rid, v_officer, 'manual_note'::public.response_log_action_type, 'Officer test activity note');

  -- 1. Existence and Type Assertions
  INSERT INTO log_audit_results VALUES (
    'auth_logs view exists',
    CASE WHEN to_regclass('public.auth_logs') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    'Relation: ' || coalesce(to_regclass('public.auth_logs')::text, 'null')
  );

  INSERT INTO log_audit_results VALUES (
    'response_log view exists',
    CASE WHEN to_regclass('public.response_log') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    'Relation: ' || coalesce(to_regclass('public.response_log')::text, 'null')
  );

  INSERT INTO log_audit_results VALUES (
    'auth_logs action_type is audit_log_action_type',
    CASE WHEN (SELECT udt_name FROM information_schema.columns WHERE table_schema='public' AND table_name='auth_logs' AND column_name='action_type') = 'audit_log_action_type' THEN 'PASS' ELSE 'FAIL' END,
    'Type verified'
  );

  INSERT INTO log_audit_results VALUES (
    'response_log action_type is response_log_action_type',
    CASE WHEN (SELECT udt_name FROM information_schema.columns WHERE table_schema='public' AND table_name='response_log' AND column_name='action_type') = 'response_log_action_type' THEN 'PASS' ELSE 'FAIL' END,
    'Type verified'
  );

  -- 2. Anonymous Access Denied
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  SET LOCAL ROLE anon;

  IF to_regclass('public.auth_logs') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.auth_logs' INTO v_count;
      INSERT INTO log_audit_results VALUES ('Anonymous cannot view auth_logs', CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END, 'Seen: ' || v_count);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Anonymous cannot view auth_logs', 'PASS', 'Permission denied: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Anonymous cannot view auth_logs', 'FAIL', 'auth_logs view does not exist');
  END IF;

  IF to_regclass('public.response_log') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.response_log' INTO v_count;
      INSERT INTO log_audit_results VALUES ('Anonymous cannot view response_log', CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END, 'Seen: ' || v_count);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Anonymous cannot view response_log', 'PASS', 'Permission denied: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Anonymous cannot view response_log', 'FAIL', 'response_log view does not exist');
  END IF;

  RESET ROLE;

  -- 3. Citizen Access Denied
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_citizen, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_citizen::text, true);
  SET LOCAL ROLE authenticated;

  IF to_regclass('public.auth_logs') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.auth_logs' INTO v_auth_count;
      INSERT INTO log_audit_results VALUES (
        'Citizen cannot view auth_logs',
        CASE WHEN v_auth_count = 0 THEN 'PASS' ELSE 'FAIL' END,
        'Seen: ' || v_auth_count
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Citizen cannot view auth_logs', 'PASS', 'Denied: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Citizen cannot view auth_logs', 'FAIL', 'auth_logs view does not exist');
  END IF;

  IF to_regclass('public.response_log') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.response_log WHERE report_id = $1' INTO v_count USING v_rid;
      INSERT INTO log_audit_results VALUES (
        'Citizen cannot view response_log',
        CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
        'Seen: ' || v_count
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Citizen cannot view response_log', 'PASS', 'Denied: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Citizen cannot view response_log', 'FAIL', 'response_log view does not exist');
  END IF;

  RESET ROLE;

  -- 4. Field Crew: Can view response_log, CANNOT view auth_logs
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_crew, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_crew::text, true);
  SET LOCAL ROLE authenticated;

  IF to_regclass('public.auth_logs') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.auth_logs' INTO v_auth_count;
      INSERT INTO log_audit_results VALUES (
        'Field crew cannot view auth_logs',
        CASE WHEN v_auth_count = 0 THEN 'PASS' ELSE 'FAIL' END,
        'Seen: ' || v_auth_count
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Field crew cannot view auth_logs', 'PASS', 'Denied: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Field crew cannot view auth_logs', 'FAIL', 'auth_logs view does not exist');
  END IF;

  IF to_regclass('public.response_log') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.response_log WHERE report_id = $1' INTO v_count USING v_rid;
      INSERT INTO log_audit_results VALUES (
        'Field crew can view response_log',
        CASE WHEN v_count > 0 THEN 'PASS' ELSE 'FAIL' END,
        'Seen: ' || v_count
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Field crew can view response_log', 'FAIL', 'Error: ' || SQLSTATE);
    END;

    BEGIN
      EXECUTE 'INSERT INTO public.response_log (report_id, user_id, action_type, action_details) VALUES ($1, $2, $3::public.response_log_action_type, $4) RETURNING id'
      INTO v_note_id USING v_rid, v_crew, 'manual_note', 'Crew field note via view';
      INSERT INTO log_audit_results VALUES (
        'Field crew can insert into response_log',
        CASE WHEN v_note_id IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
        'Inserted: ' || coalesce(v_note_id::text, 'null')
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Field crew can insert into response_log', 'FAIL', 'Error: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Field crew can view response_log', 'FAIL', 'response_log view does not exist');
    INSERT INTO log_audit_results VALUES ('Field crew can insert into response_log', 'FAIL', 'response_log view does not exist');
  END IF;

  RESET ROLE;

  -- 5. Admin: Can view both auth_logs and response_log
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  SET LOCAL ROLE authenticated;

  IF to_regclass('public.auth_logs') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.auth_logs' INTO v_auth_count;
      INSERT INTO log_audit_results VALUES (
        'Admin can view auth_logs',
        CASE WHEN v_auth_count > 0 THEN 'PASS' ELSE 'FAIL' END,
        'Seen: ' || v_auth_count
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Admin can view auth_logs', 'FAIL', 'Error: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Admin can view auth_logs', 'FAIL', 'auth_logs view does not exist');
  END IF;

  IF to_regclass('public.response_log') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.response_log WHERE report_id = $1' INTO v_count USING v_rid;
      INSERT INTO log_audit_results VALUES (
        'Admin can view response_log',
        CASE WHEN v_count > 0 THEN 'PASS' ELSE 'FAIL' END,
        'Seen: ' || v_count
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO log_audit_results VALUES ('Admin can view response_log', 'FAIL', 'Error: ' || SQLSTATE);
    END;
  ELSE
    INSERT INTO log_audit_results VALUES ('Admin can view response_log', 'FAIL', 'response_log view does not exist');
  END IF;

  RESET ROLE;
END $$;

SELECT * FROM log_audit_results ORDER BY test;
ROLLBACK;
