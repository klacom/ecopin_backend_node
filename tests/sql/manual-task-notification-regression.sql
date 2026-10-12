-- Owned local Supabase stack only. Fixture data and trigger changes roll back.
BEGIN;
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE manual_notice_results(test text,status text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.manual_notice_assert(label text,condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO manual_notice_results VALUES(label,CASE WHEN condition THEN 'PASS' ELSE 'FAIL' END);
END $$;
CREATE FUNCTION pg_temp.reject_fixture_notification() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN IF new.title='New Task Assigned' THEN RAISE EXCEPTION 'Synthetic notification storage failure'; END IF; RETURN new; END $$;
DO $$
DECLARE actor uuid; member uuid; report uuid; second_report uuid; result jsonb;
 task uuid; before_notices integer; before_tasks integer; all_notices integer; failure_seen boolean:=false;
BEGIN
 IF EXISTS(SELECT FROM cron.job WHERE active AND jobname LIKE 'ecopin-%') THEN RAISE EXCEPTION 'This test requires the isolated recovery stack with copied jobs disabled'; END IF;
 SELECT id INTO actor FROM public.profiles WHERE role::text='admin' LIMIT 1;
 SELECT id INTO member FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
 IF actor IS NULL OR member IS NULL THEN RAISE EXCEPTION 'Missing local desk/crew fixtures'; END IF;
 SELECT count(*) INTO before_notices FROM public.notifications WHERE user_id=member;
 INSERT INTO public.reports(user_id,title,description,issue_type,validation_status,status,location)
 VALUES(actor,'Local atomic notice report','Rollback-only notice verification','waste','approved','unresolved',extensions.st_setsrid(extensions.st_makepoint(121.05,14.55),4326)::extensions.geography)
 RETURNING id INTO report;
 result:=public.create_manual_cleanup_task(actor,ARRAY[report],'Local atomic assignment notice',NULL,ARRAY[member],NULL);
 task:=(result->'task'->>'id')::uuid;
 PERFORM pg_temp.manual_notice_assert('manual creation atomically creates one supported notification per assignee',
  result->>'status'='created' AND (SELECT count(*) FROM public.notifications WHERE user_id=member)=before_notices+1
  AND EXISTS(SELECT FROM public.notifications WHERE user_id=member AND report_id=report AND type='general' AND title='New Task Assigned'));
 PERFORM pg_temp.manual_notice_assert('atomic manual claim creates the canonical assignment receipt',
  EXISTS(SELECT FROM public.field_assignment_receipts WHERE task_id=task AND report_id=report AND crew_id=member));
 result:=public.create_manual_cleanup_task(actor,ARRAY[report],'Local repeat should conflict',NULL,ARRAY[member],NULL);
 PERFORM pg_temp.manual_notice_assert('retrying an already claimed report does not duplicate notifications',
  result->>'status'='conflict' AND (SELECT count(*) FROM public.notifications WHERE user_id=member)=before_notices+1);
 SELECT count(*) INTO all_notices FROM public.notifications;
 INSERT INTO public.reports(user_id,title,description,issue_type,validation_status,status,location)
 VALUES(actor,'Local unassigned notice report','Rollback-only empty-assignee verification','waste','approved','unresolved',extensions.st_setsrid(extensions.st_makepoint(121.05,14.55),4326)::extensions.geography)
 RETURNING id INTO second_report;
 result:=public.create_manual_cleanup_task(actor,ARRAY[second_report],'Local unassigned task',NULL,'{}'::uuid[],NULL);
 PERFORM pg_temp.manual_notice_assert('unassigned manual task creates no assignment notification',
  result->>'status'='created' AND (SELECT count(*) FROM public.notifications)=all_notices);
 INSERT INTO public.reports(user_id,title,description,issue_type,validation_status,status,location)
 VALUES(actor,'Local failing notice report','Rollback-only failure verification','waste','approved','unresolved',extensions.st_setsrid(extensions.st_makepoint(121.05,14.55),4326)::extensions.geography)
 RETURNING id INTO second_report;
 SELECT count(*) INTO before_tasks FROM public.cleanup_tasks;
 CREATE TRIGGER local_reject_fixture_notice BEFORE INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_fixture_notification();
 BEGIN
  PERFORM public.create_manual_cleanup_task(actor,ARRAY[second_report],'Local notice failure',NULL,ARRAY[member],NULL);
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM<>'Synthetic notification storage failure' THEN RAISE; END IF;
  failure_seen:=true;
 END;
 PERFORM pg_temp.manual_notice_assert('notification failure rolls back task creation and report claim',
  failure_seen AND (SELECT count(*) FROM public.cleanup_tasks)=before_tasks
  AND (SELECT cleanup_task_id IS NULL FROM public.reports WHERE id=second_report));
 PERFORM pg_temp.manual_notice_assert('notification failure creates no partial assignment receipt',
  NOT EXISTS(SELECT FROM public.field_assignment_receipts WHERE report_id=second_report));
END $$;
SELECT jsonb_agg(to_jsonb(t)) AS checks FROM manual_notice_results t;
ROLLBACK;
