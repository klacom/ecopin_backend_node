BEGIN; SET LOCAL statement_timeout='15s'; SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE identity_audit(test text,status text,detail text) ON COMMIT DROP;
DO $$ DECLARE officer uuid; other_officer uuid; owner_id uuid; rid uuid:=gen_random_uuid(); op text:='identity-test-'||gen_random_uuid(); original jsonb; again jsonb; k text; changed_id uuid; changed_type text; changed_actor uuid; changed_op text; changed_base bigint; changed_payload jsonb; rejected boolean; BEGIN
SELECT id INTO officer FROM public.profiles WHERE role::text='officer' LIMIT 1;
SELECT id INTO other_officer FROM public.profiles WHERE role::text='admin' LIMIT 1;
SELECT id INTO owner_id FROM public.profiles WHERE role::text='citizen' LIMIT 1;
INSERT INTO public.reports(id,user_id,title,issue_type,location,severity_score)
VALUES(rid,owner_id,'Identity rollback fixture','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),2);
original:=public.apply_fc_operation(officer,op,'fc.note.add',rid,'report','{"action":"Identity note","extra":"metadata"}',0);
again:=public.apply_fc_operation(officer,op,'fc.note.add',rid,'report','{"extra":"metadata","action":"Identity note"}',0);
INSERT INTO identity_audit VALUES('Equivalent JSON key order replays once',CASE WHEN again->>'replayed'='true' AND (SELECT count(*) FROM public.audit_logs WHERE report_id=rid)=1 THEN 'PASS' ELSE 'FAIL' END,'Canonical JSON and one side effect');
FOREACH k IN ARRAY ARRAY['actor','entity_id','entity_type','operation_type','base_version','payload','null_actor','null_entity','null_type'] LOOP
changed_actor:=CASE WHEN k='actor' THEN other_officer WHEN k='null_actor' THEN null ELSE officer END;
changed_id:=CASE WHEN k='entity_id' THEN gen_random_uuid() WHEN k='null_entity' THEN null ELSE rid END;
changed_type:=CASE WHEN k='entity_type' THEN 'task' WHEN k='null_type' THEN null ELSE 'report' END;
changed_op:=CASE WHEN k='operation_type' THEN 'fc.report.update_details' ELSE 'fc.note.add' END;
changed_base:=CASE WHEN k='base_version' THEN 1 ELSE 0 END;
changed_payload:=CASE WHEN k='payload' THEN '{"action":"Different","extra":"metadata"}'::jsonb ELSE '{"action":"Identity note","extra":"metadata"}'::jsonb END;
rejected:=false;
BEGIN
PERFORM public.apply_fc_operation(changed_actor,op,changed_op,changed_id,changed_type,changed_payload,changed_base);
EXCEPTION WHEN SQLSTATE '42501' OR SQLSTATE '22023' THEN rejected:=true; END;
INSERT INTO identity_audit VALUES('Replay rejects changed '||k,CASE WHEN rejected THEN 'PASS' ELSE 'FAIL' END,'Request identity must be immutable');
END LOOP;
INSERT INTO public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result)
VALUES(op||'-legacy',officer,'fc.note.add',rid::text,'report','success','{"status":"success"}');
rejected:=false;
BEGIN PERFORM public.apply_fc_operation(officer,op||'-legacy','fc.note.add',rid,'report','{"action":"Legacy retry"}',0);
EXCEPTION WHEN SQLSTATE '22023' THEN rejected:=true; END;
INSERT INTO identity_audit VALUES('Unknown legacy replay fails closed',CASE WHEN rejected THEN 'PASS' ELSE 'FAIL' END,'No request proof in legacy record');
INSERT INTO identity_audit SELECT 'Conflict RLS enabled',CASE WHEN relrowsecurity THEN 'PASS' ELSE 'FAIL' END,'Backend-only defense' FROM pg_class WHERE oid='public.sync_conflicts'::regclass;
INSERT INTO identity_audit SELECT 'Conflict service policy exists',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,'Explicit service-only policy' FROM pg_policies WHERE schemaname='public' AND tablename='sync_conflicts' AND policyname='sync_conflicts_service_role_all';
INSERT INTO identity_audit VALUES('Conflict client grants remain denied',CASE WHEN NOT has_table_privilege('anon','public.sync_conflicts','SELECT') AND NOT has_table_privilege('authenticated','public.sync_conflicts','SELECT') THEN 'PASS' ELSE 'FAIL' END,'RLS and grants');
END $$;
SELECT * FROM identity_audit; ROLLBACK;
