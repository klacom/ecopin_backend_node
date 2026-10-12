\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;
SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE measured (name text, result jsonb);
CREATE TEMP TABLE fixture (id uuid);
INSERT INTO fixture VALUES(gen_random_uuid());
INSERT INTO auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
SELECT id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',id::text||'@ecopin.test','synthetic-not-login',now(),'{}','{}',now(),now() FROM fixture;
UPDATE public.profiles SET role='citizen',full_name='Rolled-back WAL fixture' WHERE id=(SELECT id FROM fixture);
INSERT INTO public.reports(id,user_id,title,issue_type,location,validation_status,status,severity_score,urgency_score)
SELECT gen_random_uuid(),(SELECT id FROM fixture),'WAL fixture '||s,'waste',ST_SetSRID(ST_MakePoint(121.05,14.55),4326)::geography,'approved','unresolved',50,1 FROM generate_series(1,50)s;
INSERT INTO public.notifications(user_id,type,title,body,is_read)
SELECT (SELECT id FROM fixture),'general','WAL fixture','user-child',false FROM generate_series(1,100);
INSERT INTO public.notifications(user_id,report_id,type,title,body,is_read)
SELECT (SELECT id FROM fixture),r.id,'general','WAL fixture','report-child',false FROM public.reports r CROSS JOIN generate_series(1,2) WHERE r.user_id=(SELECT id FROM fixture);

DO $$DECLARE blocked_profile bool:=false;blocked_auth bool:=false;BEGIN
 BEGIN DELETE FROM public.profiles WHERE id=(SELECT id FROM fixture);EXCEPTION WHEN foreign_key_violation THEN blocked_profile:=true;END;
 BEGIN DELETE FROM auth.users WHERE id=(SELECT id FROM fixture);EXCEPTION WHEN foreign_key_violation THEN blocked_auth:=true;END;
 IF NOT blocked_profile OR NOT blocked_auth OR (SELECT count(*) FROM public.reports WHERE user_id=(SELECT id FROM fixture))<>50 THEN RAISE EXCEPTION 'Restrictive parent protection failed';END IF;
 INSERT INTO measured VALUES('restrictive_parent_delete',jsonb_build_object('profile_blocked',blocked_profile,'auth_blocked',blocked_auth,'reports_preserved',50));
END $$;

-- Capture global insert LSN in sequential statements; no unordered write CTE.
CREATE FUNCTION pg_temp.measure(label text, statement text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE start_lsn pg_lsn;end_lsn pg_lsn;plan jsonb;started timestamptz;elapsed numeric;
BEGIN
 started:=clock_timestamp();start_lsn:=pg_current_wal_insert_lsn();
 EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON) '||statement INTO plan;
 end_lsn:=pg_current_wal_insert_lsn();elapsed:=extract(epoch FROM clock_timestamp()-started)*1000;
 INSERT INTO measured VALUES(label,jsonb_build_object('insert_lsn_bytes',pg_wal_lsn_diff(end_lsn,start_lsn),'elapsed_ms',elapsed,'plan',plan));
END $$;

-- Identical close transition from identical rows, with only the two lifecycle
-- indexes toggled in a rolled-back subtransaction. Triggers remain enabled.
SAVEPOINT indexed;
SELECT pg_temp.measure('lifecycle_with_indexes',format('UPDATE public.reports SET status=''resolved'' WHERE user_id=%L',(SELECT id FROM fixture)));
SELECT result AS indexed_result FROM measured WHERE name='lifecycle_with_indexes' \gset
ROLLBACK TO indexed;
INSERT INTO measured VALUES('lifecycle_with_indexes',:'indexed_result'::jsonb);
SAVEPOINT no_indexes;
DROP INDEX public.reports_lifecycle_open_idx;
DROP INDEX public.reports_hazard_dispatch_review;
SELECT pg_temp.measure('lifecycle_without_indexes',format('UPDATE public.reports SET status=''resolved'' WHERE user_id=%L',(SELECT id FROM fixture)));
SELECT result AS unindexed_result FROM measured WHERE name='lifecycle_without_indexes' \gset
ROLLBACK TO no_indexes;
INSERT INTO measured VALUES('lifecycle_without_indexes',:'unindexed_result'::jsonb);

SELECT pg_temp.measure('report_parent_delete',format('DELETE FROM public.reports WHERE user_id=%L',(SELECT id FROM fixture)));
DO $$BEGIN
 IF EXISTS(SELECT 1 FROM public.reports WHERE user_id=(SELECT id FROM fixture)) OR (SELECT count(*) FROM public.notifications WHERE user_id=(SELECT id FROM fixture))<>100 THEN RAISE EXCEPTION 'Report cascade count incorrect';END IF;
 INSERT INTO measured VALUES('report_cascade_counts','{"reports_deleted":50,"report_notifications_cascaded":100,"user_notifications_retained":100}');
END $$;
-- Existing account workflow removes an empty profile, then Auth cascades its
-- notifications. It cannot remove profiles that still own report history.
SELECT pg_temp.measure('empty_profile_delete',format('DELETE FROM public.profiles WHERE id=%L',(SELECT id FROM fixture)));
SELECT pg_temp.measure('auth_parent_delete',format('DELETE FROM auth.users WHERE id=%L',(SELECT id FROM fixture)));
DO $$BEGIN
 IF EXISTS(SELECT 1 FROM public.notifications WHERE user_id=(SELECT id FROM fixture)) OR EXISTS(SELECT 1 FROM auth.users WHERE id=(SELECT id FROM fixture)) THEN RAISE EXCEPTION 'Auth cascade failed';END IF;
 INSERT INTO measured VALUES('auth_cascade_counts','{"auth_users_deleted":1,"user_notifications_cascaded":100}');
 IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='reports_lifecycle_open_idx') OR NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='reports_hazard_dispatch_review') THEN RAISE EXCEPTION 'Indexes were not restored';END IF;
END $$;
SELECT jsonb_build_object('timestamp',clock_timestamp(),'scope','private local recovery stack; all fixtures and index changes rolled back','wal_caveat','insert-LSN deltas include any concurrent background WAL; EXPLAIN node WAL and trigger timings also retained','results',jsonb_object_agg(name,result)) FROM measured;
ROLLBACK;
