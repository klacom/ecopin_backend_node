BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';
SET LOCAL storage.allow_delete_query = 'true';

CREATE TEMP TABLE storage_audit_results (
  test text,
  status text,
  detail text
) ON COMMIT DROP;
GRANT SELECT, INSERT ON storage_audit_results TO authenticated, anon, service_role;

DO $$
DECLARE
  v_crew uuid;
  v_other_crew uuid;
  v_citizen uuid;
  v_other_citizen uuid;
  v_officer uuid;
  v_admin uuid;
  v_tid uuid := gen_random_uuid();
  v_rid uuid := gen_random_uuid();
  v_obj_id uuid := gen_random_uuid();
  v_count integer;
  v_del_count integer;
BEGIN
  SELECT id INTO v_crew FROM public.profiles WHERE role::text = 'field_crew' LIMIT 1;
  SELECT id INTO v_citizen FROM public.profiles WHERE role::text = 'citizen' LIMIT 1;
  SELECT id INTO v_officer FROM public.profiles WHERE role::text = 'officer' LIMIT 1;
  SELECT id INTO v_admin FROM public.profiles WHERE role::text = 'admin' LIMIT 1;

  v_other_crew := gen_random_uuid();
  v_other_citizen := gen_random_uuid();

  INSERT INTO auth.users (id) VALUES (v_other_crew), (v_other_citizen);
  INSERT INTO public.profiles (id, full_name, role) VALUES 
    (v_other_crew, 'Synthetic other crew', 'field_crew'),
    (v_other_citizen, 'Synthetic other citizen', 'citizen')
  ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name, role = EXCLUDED.role;

  -- Setup fixture task and report
  INSERT INTO public.cleanup_tasks (id, title, status, route_status, assigned_crew_ids, report_ids)
  VALUES (v_tid, 'Storage Regression Task', 'in_progress', 'ready', ARRAY[v_crew], ARRAY[v_rid]);

  INSERT INTO public.reports (id, user_id, title, issue_type, location, severity_score, validation_status, cleanup_task_id)
  VALUES (v_rid, v_citizen, 'Storage Regression Report', 'waste', extensions.st_setsrid(extensions.st_makepoint(122, 15), 4326), 2, 'approved', v_tid);

  -- Insert test storage objects as service_role
  INSERT INTO storage.objects (id, bucket_id, name)
  VALUES 
    (v_obj_id, 'Report Evidence', v_citizen::text || '/evidence_photo.jpg'),
    (gen_random_uuid(), 'Cleanup Task Photos', v_tid::text || '/before/' || gen_random_uuid()::text || '.jpg'),
    (gen_random_uuid(), 'Report Cleanup', v_rid::text || '/after/' || gen_random_uuid()::text || '.jpg'),
    (gen_random_uuid(), 'avatars', v_citizen::text || '/avatar.png');

  -- 1. Check bucket public setting
  INSERT INTO storage_audit_results VALUES (
    'Report Evidence bucket is private',
    CASE WHEN (SELECT public FROM storage.buckets WHERE id = 'Report Evidence') IS FALSE THEN 'PASS' ELSE 'FAIL' END,
    'Expected public = false'
  );

  INSERT INTO storage_audit_results VALUES (
    'Cleanup Task Photos bucket is private',
    CASE WHEN (SELECT public FROM storage.buckets WHERE id = 'Cleanup Task Photos') IS FALSE THEN 'PASS' ELSE 'FAIL' END,
    'Expected public = false'
  );

  INSERT INTO storage_audit_results VALUES (
    'Report Cleanup bucket is private',
    CASE WHEN (SELECT public FROM storage.buckets WHERE id = 'Report Cleanup') IS FALSE THEN 'PASS' ELSE 'FAIL' END,
    'Expected public = false'
  );

  INSERT INTO storage_audit_results VALUES (
    'avatars bucket remains public',
    CASE WHEN (SELECT public FROM storage.buckets WHERE id = 'avatars') IS TRUE THEN 'PASS' ELSE 'FAIL' END,
    'Expected public = true'
  );

  -- 2. Anonymous access checks
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  SET LOCAL ROLE anon;

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Report Evidence';
  INSERT INTO storage_audit_results VALUES (
    'Anonymous cannot view Report Evidence objects',
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Cleanup Task Photos';
  INSERT INTO storage_audit_results VALUES (
    'Anonymous cannot view Cleanup Task Photos objects',
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Report Cleanup';
  INSERT INTO storage_audit_results VALUES (
    'Anonymous cannot view Report Cleanup objects',
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'avatars';
  INSERT INTO storage_audit_results VALUES (
    'Anonymous can view avatar objects',
    CASE WHEN v_count > 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  -- Anonymous cannot delete
  BEGIN
    DELETE FROM storage.objects WHERE bucket_id = 'Report Evidence' AND name = v_citizen::text || '/evidence_photo.jpg';
    GET DIAGNOSTICS v_del_count = ROW_COUNT;
    INSERT INTO storage_audit_results VALUES (
      'Anonymous delete on Report Evidence denied',
      CASE WHEN v_del_count = 0 THEN 'PASS' ELSE 'FAIL' END,
      'Deleted: ' || v_del_count
    );
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO storage_audit_results VALUES (
      'Anonymous delete on Report Evidence denied',
      'PASS',
      'Denied: ' || SQLSTATE
    );
  END;

  RESET ROLE;

  -- 3. Citizen Owner checks on Report Evidence
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_citizen, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_citizen::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Report Evidence' AND name = v_citizen::text || '/evidence_photo.jpg';
  INSERT INTO storage_audit_results VALUES (
    'Citizen owner can view own Report Evidence',
    CASE WHEN v_count = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  -- Citizen owner of report can view cleanup task photos for task linked to report
  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Cleanup Task Photos' AND name LIKE (v_tid::text || '/%');
  INSERT INTO storage_audit_results VALUES (
    'Citizen owner can view Cleanup Task Photos for own report task',
    CASE WHEN v_count = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  RESET ROLE;

  -- 4. Foreign Citizen checks
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_other_citizen, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_other_citizen::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Report Evidence' AND name = v_citizen::text || '/evidence_photo.jpg';
  INSERT INTO storage_audit_results VALUES (
    'Foreign citizen cannot view other citizen Report Evidence',
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Cleanup Task Photos' AND name LIKE (v_tid::text || '/%');
  INSERT INTO storage_audit_results VALUES (
    'Foreign citizen cannot view unrelated Cleanup Task Photos',
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  DELETE FROM storage.objects WHERE bucket_id = 'Report Evidence' AND name = v_citizen::text || '/evidence_photo.jpg';
  GET DIAGNOSTICS v_del_count = ROW_COUNT;
  INSERT INTO storage_audit_results VALUES (
    'Foreign citizen cannot delete other citizen Report Evidence',
    CASE WHEN v_del_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Deleted: ' || v_del_count
  );

  RESET ROLE;

  -- 5. Field Crew checks on Cleanup Task Photos
  -- Foreign / unassigned crew
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_other_crew, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_other_crew::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Cleanup Task Photos' AND name LIKE (v_tid::text || '/%');
  INSERT INTO storage_audit_results VALUES (
    'Unassigned crew cannot view Cleanup Task Photos',
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  DELETE FROM storage.objects WHERE bucket_id = 'Cleanup Task Photos' AND name LIKE (v_tid::text || '/%');
  GET DIAGNOSTICS v_del_count = ROW_COUNT;
  INSERT INTO storage_audit_results VALUES (
    'Unassigned crew cannot delete Cleanup Task Photos',
    CASE WHEN v_del_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Deleted: ' || v_del_count
  );

  RESET ROLE;

  -- Assigned crew
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_crew, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_crew::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Cleanup Task Photos' AND name LIKE (v_tid::text || '/%');
  INSERT INTO storage_audit_results VALUES (
    'Assigned crew can view Cleanup Task Photos',
    CASE WHEN v_count = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  DELETE FROM storage.objects WHERE bucket_id = 'Cleanup Task Photos' AND name LIKE (v_tid::text || '/%');
  GET DIAGNOSTICS v_del_count = ROW_COUNT;
  INSERT INTO storage_audit_results VALUES (
    'Assigned crew can delete Cleanup Task Photos',
    CASE WHEN v_del_count = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Deleted: ' || v_del_count
  );

  RESET ROLE;

  -- 6. Citizen owner can delete own Report Evidence
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_citizen, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_citizen::text, true);
  SET LOCAL ROLE authenticated;

  DELETE FROM storage.objects WHERE bucket_id = 'Report Evidence' AND name = v_citizen::text || '/evidence_photo.jpg';
  GET DIAGNOSTICS v_del_count = ROW_COUNT;
  INSERT INTO storage_audit_results VALUES (
    'Citizen owner can delete own Report Evidence',
    CASE WHEN v_del_count = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Deleted: ' || v_del_count
  );

  RESET ROLE;

  -- 7. Officer / Admin checks
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_officer, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_officer::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'Report Cleanup';
  INSERT INTO storage_audit_results VALUES (
    'Officer can view Report Cleanup objects',
    CASE WHEN v_count > 0 THEN 'PASS' ELSE 'FAIL' END,
    'Seen: ' || v_count
  );

  DELETE FROM storage.objects WHERE bucket_id = 'Report Cleanup' AND name LIKE (v_rid::text || '/%');
  GET DIAGNOSTICS v_del_count = ROW_COUNT;
  INSERT INTO storage_audit_results VALUES (
    'Officer can delete Report Cleanup objects',
    CASE WHEN v_del_count = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Deleted: ' || v_del_count
  );

  RESET ROLE;
END $$;

SELECT * FROM storage_audit_results ORDER BY test;
ROLLBACK;
