BEGIN;
SET LOCAL lock_timeout='5s';
-- Preserve each canonical writer's receipt/retry checks; carry notes in the same row update.
DO $$ DECLARE source text; fn record; changed integer:=0;
BEGIN
 SELECT pg_get_functiondef('public.reconcile_report_outcome(uuid,text,jsonb)'::regprocedure) INTO source;
 IF position('status=''resolved'',lgu_resolved_at=now(),updated_at=now()' IN source)=0 THEN RAISE EXCEPTION 'Unexpected receipt completion writer'; END IF;
 source:=replace(source,'status=''resolved'',lgu_resolved_at=now(),updated_at=now()',
  'status=''resolved'',cleanup_action_notes=btrim(payload->>''notes''),lgu_resolved_at=now(),updated_at=now()');
 EXECUTE source;
 SELECT pg_get_functiondef('public.submit_task_outcome(uuid,uuid,text,text,text,bigint,text)'::regprocedure) INTO source;
 IF position('status=''resolved'',lgu_resolved_at=now(),updated_at=now()' IN source)=0 THEN RAISE EXCEPTION 'Unexpected task completion writer'; END IF;
 source:=replace(source,'status=''resolved'',lgu_resolved_at=now(),updated_at=now()',
  'status=''resolved'',cleanup_action_notes=coalesce(nullif(btrim(submit_task_outcome.notes),''''),public.reports.cleanup_action_notes),lgu_resolved_at=now(),updated_at=now()');
 EXECUTE source;
 FOR fn IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE p.proname='apply_fc_operation' AND n.nspname IN ('public','workflow_private') LOOP
  source:=pg_get_functiondef(fn.oid);
  IF position('when ''fc.report.update_status'' then array[''status'']' IN source)>0 THEN
   source:=replace(source,'when ''fc.report.update_status'' then array[''status'']',
    'when ''fc.report.update_status'' then array[''status'',''cleanup_action_notes'']');
   IF position('notes = patched.notes,' IN source)=0 THEN RAISE EXCEPTION 'Unexpected offline report note writer'; END IF;
   source:=replace(source,'notes = patched.notes,','notes = patched.notes, cleanup_action_notes = patched.cleanup_action_notes,');
   EXECUTE source;
   changed:=changed+1;
  END IF;
 END LOOP;
 IF changed=0 THEN RAISE EXCEPTION 'Unexpected offline completion writer'; END IF;
END; $$;
NOTIFY pgrst,'reload schema';
COMMIT;
