BEGIN;
SET LOCAL statement_timeout='20s';
SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE task_read_results(test text,status text,detail text) ON COMMIT DROP;
GRANT INSERT,SELECT ON task_read_results TO anon,authenticated,service_role;
CREATE FUNCTION pg_temp.task_assert(label text,condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO task_read_results VALUES(label,CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END,'Condition='||coalesce(condition::text,'null')); END $$;
DO $$
DECLARE owner_id uuid; stranger uuid; crew uuid; officer uuid; admin uuid; cid uuid;
  tid uuid:=gen_random_uuid(); public_tid uuid:=gen_random_uuid(); rid uuid:=gen_random_uuid();
  public_rid uuid:=gen_random_uuid(); other_private uuid:=gen_random_uuid();
  data jsonb; actor_id uuid; caller text;
BEGIN
 SELECT id INTO owner_id FROM public.profiles WHERE role::text='citizen' LIMIT 1;
 SELECT id INTO stranger FROM public.profiles WHERE role::text='citizen' AND id<>owner_id LIMIT 1;
 SELECT id INTO crew FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
 SELECT id INTO officer FROM public.profiles WHERE role::text='officer' LIMIT 1;
 SELECT id INTO admin FROM public.profiles WHERE role::text='admin' LIMIT 1;
 SELECT id INTO cid FROM public.clusters LIMIT 1;
 IF owner_id IS NULL OR stranger IS NULL OR crew IS NULL OR officer IS NULL OR admin IS NULL OR cid IS NULL THEN RAISE EXCEPTION 'Missing synthetic-test roles/cluster'; END IF;
 INSERT INTO public.cleanup_tasks(id,title,description,cluster_id,status,route_status,assigned_crew_ids,before_photo_url,after_photo_url,report_ids)
 VALUES(tid,'Private operational title','Private operations',cid,'pending','ready',ARRAY[crew],
 'https://synthetic.invalid/before','https://synthetic.invalid/after',ARRAY[rid]),
 (public_tid,'Public cleanup task','Internal planning',cid,'pending','ready',ARRAY[crew],
 'https://synthetic.invalid/public-before','https://synthetic.invalid/public-after',ARRAY[public_rid]);
 INSERT INTO public.reports(id,user_id,title,notes,issue_type,location,validation_status,cleanup_task_id,on_private_property,property_owner_consent_status)
 VALUES(rid,owner_id,'Task read rollback fixture','Private note','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),'approved',tid,true,'denied'),
 (public_rid,owner_id,'Task read rollback fixture','Private note','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),'approved',public_tid,false,'not_required');
 FOREACH caller IN ARRAY ARRAY['anon','authenticated'] LOOP
  PERFORM set_config('role',caller,true);
  BEGIN
   PERFORM public.read_authorized_cleanup_tasks(officer,tid,cid);
   INSERT INTO task_read_results VALUES('Client cannot spoof RPC actor: '||caller,'FAIL','RPC accepted');
  EXCEPTION WHEN OTHERS THEN
   INSERT INTO task_read_results VALUES('Client cannot spoof RPC actor: '||caller,CASE WHEN SQLSTATE='42501' THEN 'PASS' ELSE 'FAIL' END,SQLSTATE);
  END;
  RESET ROLE;
 END LOOP;
 SET LOCAL ROLE service_role;
 PERFORM pg_temp.task_assert('Missing identity returns no task',public.read_authorized_cleanup_tasks(NULL,tid,cid)='[]'::jsonb);
 PERFORM pg_temp.task_assert('Unknown identity returns no task',public.read_authorized_cleanup_tasks(gen_random_uuid(),tid,cid)='[]'::jsonb);
 PERFORM pg_temp.task_assert('Citizen cannot use operational detail route',public.read_authorized_cleanup_tasks(owner_id,tid)='[]'::jsonb);
 PERFORM pg_temp.task_assert('Unrelated citizen cannot see denied-consent task',public.read_authorized_cleanup_tasks(stranger,tid,cid)='[]'::jsonb);
 data:=public.read_authorized_cleanup_tasks(owner_id,tid,cid)->0;
 PERFORM pg_temp.task_assert('Owner retains progress summary',data->>'access_level'='summary' AND data->>'status'='pending');
 PERFORM pg_temp.task_assert('Summary strips private operational fields',NOT(data ?| ARRAY['description','assigned_crew_ids','reports','report_ids','fc_version','clusters','report_claim_generations']));
 PERFORM pg_temp.task_assert('Summary does not expose operational title',data->>'title'='Cleanup progress');
 PERFORM pg_temp.task_assert('Owner retains own task media',data->>'before_photo_url'='https://synthetic.invalid/before');
 data:=public.read_authorized_cleanup_tasks(stranger,public_tid,cid)->0;
 PERFORM pg_temp.task_assert('Approved public task retains summary',data->>'access_level'='summary');
 PERFORM pg_temp.task_assert('Exact public evidence retains task media',data->>'after_photo_url'='https://synthetic.invalid/public-after');
 FOREACH actor_id IN ARRAY ARRAY[officer,admin,crew] LOOP
  data:=public.read_authorized_cleanup_tasks(actor_id,tid)->0;
  PERFORM pg_temp.task_assert('Authorized detail: '||CASE WHEN actor_id=officer THEN 'officer' WHEN actor_id=admin THEN 'admin' ELSE 'crew' END,
   data->>'access_level'='detail' AND data->>'description'='Private operations' AND jsonb_array_length(data->'reports')=1 AND data->'reports'->0->>'id'=rid::text);
 END LOOP;
 data:=public.read_authorized_cleanup_tasks(crew,tid)->0;
 PERFORM pg_temp.task_assert('Crew cluster projection cannot expose other memberships',data->'clusters'=jsonb_build_object('id',cid));
 PERFORM pg_temp.task_assert('Claim generation dictionary retained',data->'report_claim_generations' ? rid::text);
 PERFORM pg_temp.task_assert('Bounds reject zero limit',public.read_authorized_cleanup_tasks(officer,tid,NULL,false,0,0)='[]'::jsonb);
 PERFORM pg_temp.task_assert('Bounds reject excessive limit',public.read_authorized_cleanup_tasks(officer,tid,NULL,false,502,0)='[]'::jsonb);
 PERFORM pg_temp.task_assert('Bounds reject negative offset',public.read_authorized_cleanup_tasks(officer,tid,NULL,false,1,-1)='[]'::jsonb);
 PERFORM pg_temp.task_assert('Bounds reject excessive offset',public.read_authorized_cleanup_tasks(officer,tid,NULL,false,1,250001)='[]'::jsonb);
 PERFORM pg_temp.task_assert('Assigned-only staff filtering is retained',public.read_authorized_cleanup_tasks(officer,tid,NULL,true)='[]'::jsonb);
 RESET ROLE;
 UPDATE public.cleanup_tasks SET route_status='needs_replan' WHERE id=tid;
 SET LOCAL ROLE service_role;
 data:=public.read_authorized_cleanup_tasks(crew,tid)->0;
 PERFORM pg_temp.task_assert('Unready assignment retains only summary',data->>'access_level'='summary' AND NOT(data ? 'reports') AND data->>'before_photo_url' IS NULL);
 RESET ROLE;
 UPDATE public.cleanup_tasks SET route_status='ready',status='completed' WHERE id=tid;
 UPDATE public.reports SET cleanup_task_id=tid WHERE id=rid;
 SET LOCAL ROLE service_role;
 data:=public.read_authorized_cleanup_tasks(crew,tid)->0;
 PERFORM pg_temp.task_assert('Completed assignment retains only history summary',data->>'access_level'='summary' AND data->>'status'='completed' AND NOT(data ? 'reports') AND data->>'before_photo_url' IS NULL);
 RESET ROLE;
 UPDATE public.cleanup_tasks SET assigned_crew_ids='{}' WHERE id=tid;
 SET LOCAL ROLE service_role;
 PERFORM pg_temp.task_assert('Reassignment revokes all crew task access',public.read_authorized_cleanup_tasks(crew,tid)='[]'::jsonb);
 RESET ROLE;
 UPDATE public.cleanup_tasks SET report_ids=ARRAY[rid,gen_random_uuid()] WHERE id=tid;
 SET LOCAL ROLE service_role;
 data:=public.read_authorized_cleanup_tasks(owner_id,tid,cid)->0;
 PERFORM pg_temp.task_assert('Missing membership cannot grant task media',data->>'access_level'='summary' AND data->>'before_photo_url' IS NULL);
 RESET ROLE;
 INSERT INTO public.reports(id,user_id,title,issue_type,location,validation_status,on_private_property,property_owner_consent_status)
 VALUES(other_private,stranger,'Task read rollback fixture','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),'approved',true,'denied');
 UPDATE public.cleanup_tasks SET report_ids=ARRAY[rid,other_private] WHERE id=tid;
 SET LOCAL ROLE service_role;
 data:=public.read_authorized_cleanup_tasks(owner_id,tid,cid)->0;
 PERFORM pg_temp.task_assert('Mixed-owner private task media is withheld',data->>'access_level'='summary' AND data->>'before_photo_url' IS NULL AND data->>'after_photo_url' IS NULL);
 RESET ROLE;
 UPDATE public.profiles SET role='citizen' WHERE id=crew;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',crew,'role','authenticated','user_metadata',jsonb_build_object('role','admin'))::text,true);
 SET LOCAL ROLE service_role;
 PERFORM pg_temp.task_assert('Stale crew or forged metadata cannot grant detail',public.read_authorized_cleanup_tasks(crew,public_tid)='[]'::jsonb);
 RESET ROLE;
 UPDATE public.profiles SET role='field_crew' WHERE id=crew;
 PERFORM pg_temp.task_assert('RPC is invoker with empty search path',(SELECT NOT prosecdef AND proconfig=ARRAY['search_path=""'] FROM pg_proc WHERE oid='public.read_authorized_cleanup_tasks(uuid,uuid,uuid,boolean,integer,integer)'::regprocedure));
END $$;
SELECT * FROM task_read_results ORDER BY test;
ROLLBACK;

