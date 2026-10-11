BEGIN;
SET LOCAL statement_timeout='20s'; SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE cleanup_storage_results(test text,status text,detail text) ON COMMIT DROP;
GRANT SELECT,INSERT ON cleanup_storage_results TO authenticated,anon,service_role;
CREATE FUNCTION pg_temp.check_upload(label text,bucket text,path text,allowed boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    INSERT INTO storage.objects(bucket_id,name) VALUES(bucket,path);
    INSERT INTO cleanup_storage_results VALUES(label,CASE WHEN allowed THEN 'PASS' ELSE 'FAIL' END,'Insert accepted');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO cleanup_storage_results VALUES(label,CASE WHEN NOT allowed AND SQLSTATE='42501' THEN 'PASS' ELSE 'FAIL' END,SQLSTATE);
  END;
END $$;
DO $$ DECLARE crew uuid; citizen uuid; officer uuid; admin uuid; tid uuid:=gen_random_uuid(); rid uuid:=gen_random_uuid(); bucket text; prefix text; suffix text;
BEGIN
  SELECT id INTO crew FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
  SELECT id INTO citizen FROM public.profiles WHERE role::text='citizen' LIMIT 1;
  SELECT id INTO officer FROM public.profiles WHERE role::text='officer' LIMIT 1;
  SELECT id INTO admin FROM public.profiles WHERE role::text='admin' LIMIT 1;
  IF crew IS NULL OR citizen IS NULL OR officer IS NULL OR admin IS NULL THEN RAISE EXCEPTION 'Missing test roles'; END IF;
  INSERT INTO public.cleanup_tasks(id,title,status,route_status,assigned_crew_ids)
    VALUES(tid,'Cleanup storage rollback fixture','pending','ready',ARRAY[crew]);
  INSERT INTO public.reports(id,user_id,title,issue_type,location,severity_score,validation_status,cleanup_task_id)
    VALUES(rid,citizen,'Cleanup storage rollback fixture','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),2,'approved',tid);
  FOREACH bucket IN ARRAY ARRAY['Cleanup Task Photos','Report Cleanup'] LOOP
    prefix:=CASE WHEN bucket='Cleanup Task Photos' THEN tid::text ELSE rid::text END;
    suffix:=gen_random_uuid()::text;
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',crew,'role','authenticated')::text,true);
    PERFORM set_config('request.jwt.claim.sub',crew::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.check_upload(bucket||': assigned before upload',bucket,prefix||'/before/'||suffix,true);
    PERFORM pg_temp.check_upload(bucket||': assigned after upload',bucket,prefix||'/after/'||suffix,true);
    PERFORM pg_temp.check_upload(bucket||': arbitrary prefix rejected',bucket,'arbitrary/before/'||suffix,false);
    PERFORM pg_temp.check_upload(bucket||': nonexistent entity rejected',bucket,gen_random_uuid()::text||'/before/'||suffix,false);
    PERFORM pg_temp.check_upload(bucket||': wrong slot rejected',bucket,prefix||'/other/'||suffix,false);
    PERFORM pg_temp.check_upload(bucket||': nested path rejected',bucket,prefix||'/before/nested/'||suffix,false);
    PERFORM pg_temp.check_upload(bucket||': traversal rejected',bucket,prefix||'/before/..',false);
    RESET ROLE;
    UPDATE public.cleanup_tasks SET route_status='needs_replan' WHERE id=tid;
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.check_upload(bucket||': unready route rejected',bucket,prefix||'/before/'||gen_random_uuid()::text,false);
    RESET ROLE;
    UPDATE public.cleanup_tasks SET route_status='ready',status='completed' WHERE id=tid;
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.check_upload(bucket||': completed task rejected',bucket,prefix||'/before/'||gen_random_uuid()::text,false);
    RESET ROLE;
    UPDATE public.cleanup_tasks SET status='pending',assigned_crew_ids='{}' WHERE id=tid;
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.check_upload(bucket||': revoked assignment rejected',bucket,prefix||'/before/'||gen_random_uuid()::text,false);
    RESET ROLE;
    UPDATE public.cleanup_tasks SET assigned_crew_ids=ARRAY[crew] WHERE id=tid;
    -- Completing a task releases report claims; restore only this rollback fixture.
    UPDATE public.reports SET cleanup_task_id=tid WHERE id=rid;
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',citizen,'role','authenticated','user_metadata',jsonb_build_object('role','admin'))::text,true);
    PERFORM set_config('request.jwt.claim.sub',citizen::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.check_upload(bucket||': citizen forged metadata rejected',bucket,prefix||'/before/'||gen_random_uuid()::text,false);
    RESET ROLE;
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',officer,'role','authenticated')::text,true);
    PERFORM set_config('request.jwt.claim.sub',officer::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.check_upload(bucket||': officer valid entity allowed',bucket,prefix||'/before/'||gen_random_uuid()::text,true);
    PERFORM pg_temp.check_upload(bucket||': officer fabricated entity rejected',bucket,gen_random_uuid()::text||'/before/'||gen_random_uuid()::text,false);
    RESET ROLE;
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',admin,'role','authenticated')::text,true);
    PERFORM set_config('request.jwt.claim.sub',admin::text,true);
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.check_upload(bucket||': admin valid entity allowed',bucket,prefix||'/before/'||gen_random_uuid()::text,true);
    RESET ROLE;
    PERFORM set_config('request.jwt.claims','{"role":"anon"}',true);
    PERFORM set_config('request.jwt.claim.sub','',true);
    SET LOCAL ROLE anon;
    PERFORM pg_temp.check_upload(bucket||': anonymous insert rejected',bucket,prefix||'/before/'||gen_random_uuid()::text,false);
    RESET ROLE;
    SET LOCAL ROLE service_role;
    PERFORM pg_temp.check_upload(bucket||': service insert preserved',bucket,prefix||'/before/'||gen_random_uuid()::text,true);
    RESET ROLE;
  END LOOP;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',citizen,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',citizen::text,true);
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.check_upload('Citizen own evidence remains allowed','Report Evidence',citizen::text||'/'||gen_random_uuid()::text,true);
  PERFORM pg_temp.check_upload('Citizen foreign evidence remains denied','Report Evidence',crew::text||'/'||gen_random_uuid()::text,false);
  PERFORM pg_temp.check_upload('Citizen own avatar remains allowed','avatars',citizen::text||'/'||gen_random_uuid()::text,true);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',crew,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',crew::text,true);
  SET LOCAL ROLE authenticated;
  INSERT INTO cleanup_storage_results VALUES('Null bucket rejected',CASE WHEN storage_authority.can_upload_cleanup_object(NULL,tid::text||'/before/file') IS FALSE THEN 'PASS' ELSE 'FAIL' END,NULL);
  INSERT INTO cleanup_storage_results VALUES('Unknown bucket rejected',CASE WHEN storage_authority.can_upload_cleanup_object('unknown',tid::text||'/before/file') IS FALSE THEN 'PASS' ELSE 'FAIL' END,NULL);
  INSERT INTO cleanup_storage_results VALUES('Null path rejected',CASE WHEN storage_authority.can_upload_cleanup_object('Cleanup Task Photos',NULL) IS FALSE THEN 'PASS' ELSE 'FAIL' END,NULL);
  INSERT INTO cleanup_storage_results VALUES('Uppercase photo slot rejected',CASE WHEN storage_authority.can_upload_cleanup_object('Cleanup Task Photos',tid::text||'/BEFORE/file') IS FALSE THEN 'PASS' ELSE 'FAIL' END,NULL);
  INSERT INTO cleanup_storage_results VALUES('Anonymous helper execution denied',CASE WHEN NOT has_function_privilege('anon','storage_authority.can_upload_cleanup_object(text,text)','EXECUTE') THEN 'PASS' ELSE 'FAIL' END,NULL);
  INSERT INTO cleanup_storage_results VALUES('Clients cannot create private schema objects',CASE WHEN NOT has_schema_privilege('authenticated','storage_authority','CREATE') THEN 'PASS' ELSE 'FAIL' END,NULL);
  RESET ROLE;
  REVOKE SELECT ON public.profiles,public.reports,public.cleanup_tasks FROM authenticated;
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.check_upload('Task upload survives restrictive base table grants','Cleanup Task Photos',tid::text||'/before/'||gen_random_uuid()::text,true);
  PERFORM pg_temp.check_upload('Report upload survives restrictive base table grants','Report Cleanup',rid::text||'/before/'||gen_random_uuid()::text,true);
  PERFORM set_config('request.jwt.claims','{}',true);
  PERFORM set_config('request.jwt.claim.sub','',true);
  INSERT INTO cleanup_storage_results VALUES('Null identity rejected',CASE WHEN storage_authority.can_upload_cleanup_object('Cleanup Task Photos',tid::text||'/before/file') IS FALSE THEN 'PASS' ELSE 'FAIL' END,NULL);
  RESET ROLE;
END $$;
SELECT * FROM cleanup_storage_results ORDER BY test;
ROLLBACK;
