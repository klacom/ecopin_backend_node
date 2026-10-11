BEGIN; SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='15s';
CREATE TEMP TABLE detail_access_audit(test text,status text) ON COMMIT DROP;
DO $$ DECLARE owner_id uuid; other_id uuid; crew_id uuid; officer_id uuid; admin_id uuid; task_id uuid:=gen_random_uuid(); rid uuid:=gen_random_uuid(); result jsonb; BEGIN
SELECT id INTO owner_id FROM public.profiles WHERE role::text='citizen' LIMIT 1;
SELECT id INTO other_id FROM public.profiles WHERE role::text='citizen' AND id<>owner_id LIMIT 1;
SELECT id INTO crew_id FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
SELECT id INTO officer_id FROM public.profiles WHERE role::text='officer' LIMIT 1;
SELECT id INTO admin_id FROM public.profiles WHERE role::text='admin' LIMIT 1;
IF to_regprocedure('public.read_authorized_report_detail(uuid,uuid)') IS NULL THEN
 INSERT INTO detail_access_audit VALUES('Atomic authorized detail reader exists','FAIL'); RETURN; END IF;
INSERT INTO public.cleanup_tasks(id,title,status,route_status,assigned_crew_ids) VALUES(task_id,'Detail access rollback fixture','pending','ready',ARRAY[crew_id]);
INSERT INTO public.reports(id,user_id,title,notes,issue_type,location,severity_score,validation_status,cleanup_task_id,on_private_property,property_owner_consent_status)
VALUES(rid,owner_id,'Detail access rollback fixture','Sensitive internal detail','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),2,'approved',task_id,true,'denied');
result:=public.read_authorized_report_detail(owner_id,rid);
INSERT INTO detail_access_audit VALUES('Owner retains private detail',CASE WHEN result->>'notes'='Sensitive internal detail' THEN 'PASS' ELSE 'FAIL' END);
result:=public.read_authorized_report_detail(other_id,rid);
INSERT INTO detail_access_audit VALUES('Unrelated citizen cannot read detail',CASE WHEN result IS NULL THEN 'PASS' ELSE 'FAIL' END);
result:=public.read_authorized_report_detail(officer_id,rid);
INSERT INTO detail_access_audit VALUES('Officer retains private detail',CASE WHEN result->>'notes'='Sensitive internal detail' THEN 'PASS' ELSE 'FAIL' END);
result:=public.read_authorized_report_detail(admin_id,rid);
INSERT INTO detail_access_audit VALUES('Admin retains private detail',CASE WHEN result->>'notes'='Sensitive internal detail' THEN 'PASS' ELSE 'FAIL' END);
result:=public.read_authorized_report_detail(crew_id,rid);
INSERT INTO detail_access_audit VALUES('Current assigned crew reads detail',CASE WHEN result->>'notes'='Sensitive internal detail' THEN 'PASS' ELSE 'FAIL' END);
UPDATE public.cleanup_tasks SET route_status='needs_replan' WHERE id=task_id;
INSERT INTO detail_access_audit VALUES('Unready assignment hides detail',CASE WHEN public.read_authorized_report_detail(crew_id,rid) IS NULL THEN 'PASS' ELSE 'FAIL' END);
UPDATE public.cleanup_tasks SET route_status='ready',assigned_crew_ids='{}' WHERE id=task_id;
INSERT INTO detail_access_audit VALUES('Reassigned crew immediately loses detail',CASE WHEN public.read_authorized_report_detail(crew_id,rid) IS NULL THEN 'PASS' ELSE 'FAIL' END);
INSERT INTO detail_access_audit VALUES('Null actor cannot read detail',CASE WHEN public.read_authorized_report_detail(NULL,rid) IS NULL THEN 'PASS' ELSE 'FAIL' END);
INSERT INTO detail_access_audit VALUES('Nonexistent actor cannot read detail',CASE WHEN public.read_authorized_report_detail(gen_random_uuid(),rid) IS NULL THEN 'PASS' ELSE 'FAIL' END);
INSERT INTO detail_access_audit VALUES('Anonymous direct execution denied',CASE WHEN NOT has_function_privilege('anon','public.read_authorized_report_detail(uuid,uuid)','EXECUTE') THEN 'PASS' ELSE 'FAIL' END);
INSERT INTO detail_access_audit VALUES('Authenticated direct execution denied',CASE WHEN NOT has_function_privilege('authenticated','public.read_authorized_report_detail(uuid,uuid)','EXECUTE') THEN 'PASS' ELSE 'FAIL' END);
INSERT INTO detail_access_audit VALUES('Service execution allowed',CASE WHEN has_function_privilege('service_role','public.read_authorized_report_detail(uuid,uuid)','EXECUTE') THEN 'PASS' ELSE 'FAIL' END);
END $$; SELECT * FROM detail_access_audit; ROLLBACK;
