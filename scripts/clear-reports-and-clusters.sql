-- NON-PRODUCTION RESET: deletes reports and their linked audit history.
-- Accounts, crews, settings, strikes, system logs and account-only audits stay.
-- Run this entire SINGLE statement as postgres, with backend workers paused.
-- If an earlier transaction failed, run ROLLBACK; separately first.
-- No temporary tables or preceding setup statements are required.
DO $purge$
DECLARE
  targets CONSTANT jsonb := '[
    ["field_load_events","TRUE"], ["field_task_failure_events","TRUE"],
    ["task_report_outcomes","TRUE"], ["report_resolution_events","TRUE"],
    ["field_assignment_receipts","TRUE"], ["route_waypoints","TRUE"],
    ["dispatch_access_blocks","TRUE"], ["dispatch_plan_items","TRUE"],
    ["dispatch_group_commits","TRUE"], ["plan_generation_jobs","TRUE"],
    ["cleanup_tasks","TRUE"], ["crew_routes","TRUE"],
    ["dispatch_plans","TRUE"], ["optimization_runs","TRUE"],
    ["manual_review_queue","strike_id IS NULL"],
    ["notifications","report_id IS NOT NULL"],
    ["audit_logs","report_id IS NOT NULL"],
    ["reports","TRUE"], ["clusters","TRUE"],
    ["hotspot_accuracy","TRUE"], ["hotspot_predictions","TRUE"],
    ["sweeper_audit_log","TRUE"], ["fc_operation_log","TRUE"],
    ["fc_conflict_audit","TRUE"], ["sync_conflicts","TRUE"]
  ]'::jsonb;
  protected_specs CONSTANT jsonb := '[
    ["profiles","TRUE"], ["field_crews","TRUE"],
    ["system_settings","TRUE"], ["system_logs","TRUE"], ["strikes","TRUE"],
    ["optimization_settings","TRUE"], ["optimization_templates","TRUE"],
    ["sweeper_configuration","TRUE"], ["work_time_configuration","TRUE"],
    ["email_verifications","TRUE"], ["audit_logs","report_id IS NULL"]
  ]'::jsonb;
  fingerprints jsonb := '{}'::jsonb;
  trigger_modes jsonb;
  spec jsonb;
  table_name text;
  predicate text;
  fingerprint text;
  remaining bigint;
  deleted bigint;
BEGIN
  PERFORM set_config('lock_timeout','5s',true);
  PERFORM set_config('statement_timeout','120s',true);
  PERFORM pg_advisory_xact_lock(72631016);

  -- Acquire every operational lock before modifying any row.
  FOR spec IN SELECT value FROM jsonb_array_elements(targets) ORDER BY value->>0 LOOP
    table_name := spec->>0;
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE n.nspname='public' AND c.relname=table_name AND c.relkind IN ('r','p')) THEN
      RAISE EXCEPTION 'Required purge table public.% is absent or is not a table; nothing deleted',table_name;
    END IF;
    EXECUTE format('LOCK TABLE public.%I IN SHARE ROW EXCLUSIVE MODE',table_name);
  END LOOP;

  FOR spec IN SELECT value FROM jsonb_array_elements(protected_specs) ORDER BY value->>0 LOOP
    table_name := spec->>0;
    predicate := spec->>1;
    EXECUTE format('LOCK TABLE public.%I IN SHARE MODE',table_name);
    EXECUTE format('SELECT md5(COALESCE(string_agg(to_jsonb(r)::text, E''\n'' ORDER BY to_jsonb(r)::text),'''')) FROM public.%I r WHERE %s',table_name,predicate) INTO fingerprint;
    fingerprints := fingerprints || jsonb_build_object(table_name,fingerprint);
  END LOOP;

  -- Already-disabled triggers stay disabled. Save only enabled known blockers.
  -- Foreign keys, RLS policies and other triggers are not changed here.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table_name',c.relname,'trigger_name',t.tgname,'mode',t.tgenabled
  )),'[]'::jsonb) INTO trigger_modes
  FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
  JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgenabled<>'D' AND (
    (c.relname='dispatch_group_commits' AND t.tgname='immutable_group_result') OR
    (c.relname='audit_logs' AND p.proname='prevent_audit_modification')
  );
  FOR spec IN SELECT value FROM jsonb_array_elements(trigger_modes) LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER %I',spec->>'table_name',spec->>'trigger_name');
  END LOOP;

  -- Release active report claims, then break the known circular references.
  UPDATE public.cleanup_tasks SET status='cancelled'
    WHERE status::text NOT IN ('completed','cancelled');
  UPDATE public.reports SET cleanup_task_id=NULL,cluster_id=NULL,manual_review_id=NULL;
  UPDATE public.cleanup_tasks SET crew_route_id=NULL,source_plan_id=NULL,cluster_id=NULL;
  UPDATE public.dispatch_plans SET generation_job_id=NULL,optimization_run_id=NULL;
  UPDATE public.plan_generation_jobs SET plan_id=NULL;
  UPDATE public.manual_review_queue SET report_id=NULL WHERE report_id IS NOT NULL;

  -- JSON array order is the explicit child-to-parent deletion order.
  FOR spec IN SELECT value FROM jsonb_array_elements(targets) LOOP
    table_name := spec->>0;
    predicate := spec->>1;
    EXECUTE format('DELETE FROM public.%I WHERE %s',table_name,predicate);
    GET DIAGNOSTICS deleted = ROW_COUNT;
    RAISE NOTICE '%: deleted % rows',table_name,deleted;
  END LOOP;

  FOR spec IN SELECT value FROM jsonb_array_elements(targets) LOOP
    table_name := spec->>0;
    EXECUTE format('SELECT count(*) FROM public.%I WHERE %s',table_name,spec->>1) INTO remaining;
    IF remaining<>0 THEN
      RAISE EXCEPTION 'Incomplete purge: % still has % targeted rows',table_name,remaining;
    END IF;
  END LOOP;
  FOR spec IN SELECT value FROM jsonb_array_elements(protected_specs) LOOP
    table_name := spec->>0;
    EXECUTE format('SELECT md5(COALESCE(string_agg(to_jsonb(r)::text, E''\n'' ORDER BY to_jsonb(r)::text),'''')) FROM public.%I r WHERE %s',table_name,spec->>1) INTO fingerprint;
    IF fingerprint IS DISTINCT FROM fingerprints->>table_name THEN
      RAISE EXCEPTION 'Protected table % changed; rolling back purge',table_name;
    END IF;
  END LOOP;
  FOR spec IN SELECT value FROM jsonb_array_elements(trigger_modes) LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE %s TRIGGER %I',spec->>'table_name',
      CASE spec->>'mode' WHEN 'A' THEN 'ALWAYS' WHEN 'R' THEN 'REPLICA' ELSE '' END,spec->>'trigger_name');
  END LOOP;
  RAISE NOTICE 'Purge complete: all targeted counts are zero; protected data is unchanged. Trigger settings match their starting state.';
END;
$purge$;
