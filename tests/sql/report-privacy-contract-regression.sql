BEGIN; SET LOCAL statement_timeout='20s'; SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE report_contract_results(test text,status text,detail text) ON COMMIT DROP;
GRANT SELECT,INSERT ON report_contract_results TO anon,authenticated,service_role;
CREATE FUNCTION pg_temp.report_visible(label text,relation regclass,rid uuid,expected boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE rows integer;
BEGIN
  EXECUTE format('SELECT count(*) FROM %s WHERE id=$1',relation) INTO rows USING rid;
  INSERT INTO report_contract_results VALUES(label,CASE WHEN (rows=1)=expected THEN 'PASS' ELSE 'FAIL' END,'Visible='||rows);
END $$;
DO $$ DECLARE owner_id uuid; other_id uuid; crew uuid; officer uuid; admin uuid; tid uuid:=gen_random_uuid(); private_id uuid:=gen_random_uuid(); public_id uuid:=gen_random_uuid(); pending_id uuid:=gen_random_uuid(); actor uuid; relation regclass;
BEGIN
  SELECT id INTO owner_id FROM public.profiles WHERE role::text='citizen' LIMIT 1;
  SELECT id INTO other_id FROM public.profiles WHERE role::text='citizen' AND id<>owner_id LIMIT 1;
  SELECT id INTO crew FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
  SELECT id INTO officer FROM public.profiles WHERE role::text='officer' LIMIT 1;
  SELECT id INTO admin FROM public.profiles WHERE role::text='admin' LIMIT 1;
  IF owner_id IS NULL OR other_id IS NULL OR crew IS NULL OR officer IS NULL OR admin IS NULL THEN RAISE EXCEPTION 'Missing roles'; END IF;
  INSERT INTO public.cleanup_tasks(id,title,status,route_status,assigned_crew_ids) VALUES(tid,'Report contract rollback fixture','pending','ready',ARRAY[crew]);
  INSERT INTO public.reports(id,user_id,title,notes,issue_type,location,severity_score,validation_status,cleanup_task_id,on_private_property,property_owner_consent_status)
    VALUES(private_id,owner_id,'Report contract rollback fixture','Internal note','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),2,'approved',tid,true,'denied'),
    (public_id,owner_id,'Report contract rollback fixture','Internal note','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),2,'approved',NULL,false,'not_required'),
    (pending_id,other_id,'Report contract rollback fixture','Internal note','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),2,'pending',NULL,false,'not_required');
  PERFORM set_config('request.jwt.claims','{"role":"anon"}',true);
  PERFORM set_config('request.jwt.claim.sub','',true);
  SET LOCAL ROLE anon;
  FOREACH relation IN ARRAY ARRAY['public.reports'::regclass,'public.reports_view'::regclass] LOOP
    BEGIN
      EXECUTE format('SELECT id FROM %s WHERE id=$1',relation) USING public_id;
      INSERT INTO report_contract_results VALUES('Anonymous direct access denied: '||relation,'FAIL','Direct base/detail read accepted');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO report_contract_results VALUES('Anonymous direct access denied: '||relation,CASE WHEN SQLSTATE='42501' THEN 'PASS' ELSE 'FAIL' END,SQLSTATE);
    END;
  END LOOP;
  PERFORM pg_temp.report_visible('Anonymous public feed retains approved report','public.public_reports',public_id,true);
  PERFORM pg_temp.report_visible('Anonymous public feed hides denied private report','public.public_reports',private_id,false);
  PERFORM pg_temp.report_visible('Anonymous public feed hides pending report','public.public_reports',pending_id,false);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',other_id,'role','authenticated','user_metadata',jsonb_build_object('role','admin'))::text,true);
  PERFORM set_config('request.jwt.claim.sub',other_id::text,true);
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.report_visible('Unrelated citizen cannot read private base row','public.reports',private_id,false);
  PERFORM pg_temp.report_visible('Unrelated citizen cannot read private detail view','public.reports_view',private_id,false);
  PERFORM pg_temp.report_visible('Public base rows cannot expose other-owner notes','public.reports',public_id,false);
  PERFORM pg_temp.report_visible('Public detail view cannot expose other-owner notes','public.reports_view',public_id,false);
  PERFORM pg_temp.report_visible('Citizen retains own pending report','public.reports',pending_id,true);
  PERFORM pg_temp.report_visible('Citizen retains safe public feed','public.public_reports',public_id,true);
  PERFORM pg_temp.report_visible('Citizen safe feed hides denied private report','public.public_reports',private_id,false);
  RESET ROLE;
  FOREACH actor IN ARRAY ARRAY[owner_id,officer,admin,crew] LOOP
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
    PERFORM set_config('request.jwt.claim.sub',actor::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.report_visible('Authorized base detail: '||CASE WHEN actor=owner_id THEN 'owner' WHEN actor=officer THEN 'officer' WHEN actor=admin THEN 'admin' ELSE 'assigned crew' END,'public.reports',private_id,true);
    PERFORM pg_temp.report_visible('Authorized invoker view: '||CASE WHEN actor=owner_id THEN 'owner' WHEN actor=officer THEN 'officer' WHEN actor=admin THEN 'admin' ELSE 'assigned crew' END,'public.reports_view',private_id,true);
    RESET ROLE;
  END LOOP;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',crew,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',crew::text,true);
  UPDATE public.cleanup_tasks SET route_status='needs_replan' WHERE id=tid;
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.report_visible('Unready crew cannot read base details','public.reports',private_id,false);
  PERFORM pg_temp.report_visible('Unready crew cannot read view details','public.reports_view',private_id,false);
  RESET ROLE;
  UPDATE public.cleanup_tasks SET route_status='ready',assigned_crew_ids='{}' WHERE id=tid;
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.report_visible('Reassigned crew loses base detail','public.reports',private_id,false);
  PERFORM pg_temp.report_visible('Reassigned crew loses view detail','public.reports_view',private_id,false);
  RESET ROLE;
  UPDATE public.cleanup_tasks SET assigned_crew_ids=ARRAY[crew],status='completed' WHERE id=tid;
  -- Deliberately retain a stale claim to ensure task state also gates visibility.
  UPDATE public.reports SET cleanup_task_id=tid WHERE id=private_id;
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.report_visible('Completed task cannot grant crew base detail','public.reports',private_id,false);
  PERFORM pg_temp.report_visible('Completed task cannot grant crew view detail','public.reports_view',private_id,false);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims','{"role":"authenticated"}',true);
  PERFORM set_config('request.jwt.claim.sub','',true);
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.report_visible('Missing identity cannot read base detail','public.reports',private_id,false);
  RESET ROLE;
  SET LOCAL ROLE service_role;
  PERFORM pg_temp.report_visible('Service access remains available','public.reports',private_id,true);
  RESET ROLE;
END $$;
SELECT * FROM report_contract_results ORDER BY test;
ROLLBACK;
