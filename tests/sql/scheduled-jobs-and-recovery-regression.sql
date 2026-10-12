-- Run only in the owned local Supabase recovery database. All row changes roll back.
-- Real overlap is checked separately using two physical connections; transaction
-- advisory locks are reentrant, so reacquiring one here must succeed.
BEGIN;
SET LOCAL statement_timeout='30s';
SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE w08_results(test text,status text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.w08_assert(label text,condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'Scheduled-job regression failed: %',label; END IF;
 INSERT INTO w08_results VALUES(label,'PASS');
END $$;
DO $$
DECLARE
 actor uuid;
 report uuid;
 task uuid;
 job uuid;
 result jsonb;
 initial_clock timestamptz:=statement_timestamp()-interval '40 hours';
 initial_deadline timestamptz:=statement_timestamp()-interval '2 hours';
BEGIN
 IF current_database()<>'postgres' OR current_setting('port')<>'5432' THEN RAISE EXCEPTION 'Unexpected local test database'; END IF;
 PERFORM pg_temp.w08_assert('three source cron definitions restored',
  (SELECT count(*)=3 FROM cron.job WHERE
   (jobname='ecopin-report-lifecycle' AND schedule='0 * * * *') OR
   (jobname='ecopin-dispatch-watchdog' AND schedule='*/5 * * * *') OR
   (jobname='ecopin-retention-maintenance' AND schedule='39 * * * *')));
 PERFORM pg_temp.w08_assert('local copied schedules disabled during data verification',
  NOT EXISTS(SELECT FROM cron.job WHERE active AND jobname LIKE 'ecopin-%'));
 PERFORM pg_temp.w08_assert('transaction advisory locks are reentrant',
  pg_try_advisory_xact_lock(72631008) AND pg_try_advisory_xact_lock(72631008));
 SELECT id INTO actor FROM public.profiles WHERE role::text='admin' LIMIT 1;
 IF actor IS NULL THEN RAISE EXCEPTION 'No local desk fixture'; END IF;
 INSERT INTO public.reports(user_id,title,description,issue_type,status,severity_score,location)
 VALUES(actor,'Local W08 catch-up fixture','Rollback-only scheduler regression','waste','unresolved',75,
  extensions.st_setsrid(extensions.st_makepoint(121.05,14.55),4326)::extensions.geography)
 RETURNING id INTO report;
 -- Model stored pre-outage state without having an ordinary update recompute it.
 PERFORM set_config('session_replication_role','replica',true);
 UPDATE public.reports SET sla_started_at=initial_clock,deadline_at=initial_deadline,
  matured_at=NULL,breached_at=NULL,lifecycle_state='fresh' WHERE id=report;
 PERFORM set_config('session_replication_role','origin',true);
 result:=public.advance_report_lifecycle();
 PERFORM pg_temp.w08_assert('same-transaction held lock does not block its owner',
  coalesce((result->>'skipped')::boolean,false)=false);
 PERFORM pg_temp.w08_assert('outage catch-up records SLA breach',
  (SELECT lifecycle_state='sla_breached' AND breached_at IS NOT NULL FROM public.reports WHERE id=report));
 PERFORM pg_temp.w08_assert('catch-up preserves the exact SLA start and deadline',
  (SELECT sla_started_at=initial_clock AND deadline_at=initial_deadline FROM public.reports WHERE id=report));
 result:=public.advance_report_lifecycle();
 PERFORM pg_temp.w08_assert('immediate lifecycle rerun is idempotent',
  (result->>'changedCount')::integer=0 AND result->'newlyBreached'='[]'::jsonb);
 result:=public.enqueue_plan_generation(actor,'standard','{"mode":"standard"}'::jsonb,
  'local-w08-'||extensions.gen_random_uuid()::text);
 job:=(result->>'jobId')::uuid;
 UPDATE public.plan_generation_jobs SET status='running',worker_token=extensions.gen_random_uuid(),
  started_at=statement_timestamp()-interval '1 hour',lease_until=statement_timestamp()-interval '1 second'
 WHERE id=job;
 PERFORM public.expire_unpublished_dispatch_claims();
 PERFORM pg_temp.w08_assert('watchdog recovers an expired worker lease',
  (SELECT status='failed' AND error_code='worker_lease_expired' FROM public.plan_generation_jobs WHERE id=job));
 INSERT INTO public.cleanup_tasks(created_by,title,status,route_status,routing_deadline_at,task_type,location)
 VALUES(actor,'Local W08 routing fixture','pending','needs_replan',statement_timestamp()+interval '10 minutes','Cleanup',
  extensions.st_setsrid(extensions.st_makepoint(121.05,14.55),4326)::extensions.geography) RETURNING id INTO task;
 PERFORM public.expire_unpublished_dispatch_claims();
 PERFORM pg_temp.w08_assert('watchdog records near-deadline routing escalation',
  (SELECT routing_escalated_at IS NOT NULL FROM public.cleanup_tasks WHERE id=task));
 UPDATE public.cleanup_tasks SET routing_deadline_at=statement_timestamp()-interval '1 minute' WHERE id=task;
 PERFORM public.expire_unpublished_dispatch_claims();
 PERFORM pg_temp.w08_assert('watchdog expires unpublished unassigned routing tasks',
  (SELECT route_status='expired' AND status::text='cancelled' FROM public.cleanup_tasks WHERE id=task));
 PERFORM pg_temp.w08_assert('maturation and breach have exact UTC boundaries',
  workflow_private.derive_report_lifecycle('unresolved',NULL,NULL,'2026-01-01T00:00:00Z','2026-01-02T00:00:00Z',12,'2026-01-01T11:59:59Z')='fresh'
  AND workflow_private.derive_report_lifecycle('unresolved',NULL,NULL,'2026-01-01T00:00:00Z','2026-01-02T00:00:00Z',12,'2026-01-01T12:00:00Z')='maturing'
  AND workflow_private.derive_report_lifecycle('unresolved',NULL,NULL,'2026-01-01T00:00:00Z','2026-01-02T00:00:00Z',12,'2026-01-02T00:00:00Z')='sla_breached');
 result:=workflow_private.run_retention_maintenance(500);
 PERFORM pg_temp.w08_assert('retention maintenance returns its bounded result',
  (result->>'skipped')::boolean=false AND (result->>'deleted_tokens')::integer BETWEEN 0 AND 500
  AND (result->>'deleted_cron_runs')::integer BETWEEN 0 AND 500);
END $$;
SELECT jsonb_agg(to_jsonb(r)) AS checks FROM w08_results r;
ROLLBACK;
