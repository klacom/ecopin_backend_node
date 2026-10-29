BEGIN;
SET LOCAL lock_timeout='5s';
CREATE SCHEMA IF NOT EXISTS operational_private;
REVOKE ALL ON SCHEMA operational_private FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA operational_private TO service_role;
CREATE TABLE public.operational_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 event_key text NOT NULL UNIQUE,
 event_type text NOT NULL CHECK(event_type IN ('assignment','acknowledgement','arrival','evidence_submission','completion','verification')),
 task_id uuid,
 report_id uuid,
 actor_id uuid,
 assignment_generation bigint,
 occurred_at timestamptz NOT NULL,
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 time_basis text NOT NULL CHECK(time_basis IN ('server','device_reported')),
 details jsonb NOT NULL DEFAULT '{}'::jsonb,
 CHECK(task_id IS NOT NULL OR report_id IS NOT NULL),
 CONSTRAINT operational_event_clock_range CHECK(
  isfinite(occurred_at) AND occurred_at >= '2020-01-01T00:00:00Z'::timestamptz AND occurred_at < '10000-01-01T00:00:00Z'::timestamptz AND
  isfinite(recorded_at) AND recorded_at >= '2020-01-01T00:00:00Z'::timestamptz AND recorded_at < '10000-01-01T00:00:00Z'::timestamptz)
);
CREATE INDEX operational_events_task ON public.operational_events(task_id,id DESC);
CREATE INDEX operational_events_report ON public.operational_events(report_id,id DESC);
ALTER TABLE public.operational_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.operational_events FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT ON public.operational_events TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.operational_events_id_seq TO service_role;
CREATE FUNCTION operational_private.immutable_event() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'Operational events are append-only' USING ERRCODE='42501'; END; $$;
CREATE TRIGGER immutable_operational_event BEFORE UPDATE OR DELETE OR TRUNCATE ON public.operational_events
 FOR EACH STATEMENT EXECUTE FUNCTION operational_private.immutable_event();

-- These input-only fields bridge existing REST mutations into the same database transaction.
-- They are cleared before storage; the permanent attribution lives only in the journal.
ALTER TABLE public.reports ADD COLUMN operational_actor_id uuid CHECK(operational_actor_id IS NULL);
ALTER TABLE public.cleanup_tasks ADD COLUMN operational_actor_id uuid CHECK(operational_actor_id IS NULL);
REVOKE INSERT(operational_actor_id),UPDATE(operational_actor_id) ON public.reports,public.cleanup_tasks FROM anon,authenticated;
CREATE FUNCTION operational_private.set_context(actor uuid,payload jsonb DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF current_user NOT IN ('postgres','service_role','supabase_admin') THEN RAISE EXCEPTION 'Trusted operational writer required' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin','field_crew')) THEN
  RAISE EXCEPTION 'Operational actor required' USING ERRCODE='42501';
 END IF;
 IF payload IS NOT NULL OR current_setting('ecopin.operational_actor',true) IS DISTINCT FROM actor::text THEN
  PERFORM set_config('ecopin.operational_receipt',coalesce(payload,'{}'::jsonb)::text,true);
 END IF;
 PERFORM set_config('ecopin.operational_actor',actor::text,true);
END; $$;
CREATE FUNCTION operational_private.row_context() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.operational_actor_id IS NOT NULL THEN
  PERFORM operational_private.set_context(NEW.operational_actor_id);
  NEW.operational_actor_id:=NULL;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER operational_actor_context BEFORE INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION operational_private.row_context();
CREATE TRIGGER operational_actor_context BEFORE INSERT OR UPDATE ON public.cleanup_tasks FOR EACH ROW EXECUTE FUNCTION operational_private.row_context();
CREATE FUNCTION operational_private.emit(kind text,task uuid,report uuid,actor uuid,generation bigint,stamp timestamptz,basis text,dedupe text,metadata jsonb DEFAULT '{}'::jsonb) RETURNS void
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 INSERT INTO public.operational_events(event_key,event_type,task_id,report_id,actor_id,assignment_generation,occurred_at,time_basis,details)
 VALUES(md5(dedupe),kind,task,report,actor,generation,stamp,basis,metadata)
 ON CONFLICT(event_key) DO NOTHING;
$$;
CREATE FUNCTION operational_private.arrival(receipt jsonb,task uuid,report uuid,actor uuid,generation bigint,disposition text) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE stamp timestamptz; received timestamptz:=clock_timestamp();
BEGIN
 IF receipt IS NULL OR receipt->>'verification' IS DISTINCT FROM 'device_gps' OR
  receipt->>'crew_id' IS DISTINCT FROM actor::text OR receipt->>'task_id' IS DISTINCT FROM task::text OR
  receipt->>'assignment_generation' IS DISTINCT FROM generation::text OR
  (report IS NOT NULL AND receipt->>'incident_id' IS DISTINCT FROM report::text) THEN RETURN; END IF;
 BEGIN stamp:=(receipt->>'arrived_at')::timestamptz; EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN RETURN; END;
 -- Operational receipts predate neither the system nor the browser-compatible calendar range.
 IF stamp IS NULL OR NOT isfinite(stamp) OR stamp<'2020-01-01T00:00:00Z'::timestamptz OR stamp>received+interval '5 minutes' THEN RETURN; END IF;
 PERFORM operational_private.emit('arrival',task,report,actor,generation,stamp,'device_reported',
  concat('arrival:',task,':',report,':',actor,':',generation,':',receipt->>'report_claim_generation',':',extract(epoch FROM stamp)),
  jsonb_build_object('provenance','device_gps_receipt','disposition',disposition));
END; $$;
CREATE FUNCTION operational_private.capture_row() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE n jsonb:=to_jsonb(NEW); o jsonb:=CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
 actor uuid:=nullif(current_setting('ecopin.operational_actor',true),'')::uuid;
 receipt jsonb:=coalesce(nullif(current_setting('ecopin.operational_receipt',true),''),'{}')::jsonb;
 task uuid; report uuid; generation bigint; stamp timestamptz:=clock_timestamp(); slot text; photo jsonb; photos jsonb; previous jsonb; assigned boolean;
BEGIN
 IF TG_TABLE_NAME='cleanup_tasks' THEN
  task:=NEW.id;generation:=coalesce((n->>'assignment_generation')::bigint,0);
  assigned:=(CASE WHEN jsonb_typeof(n->'assigned_crew_ids')='array' THEN jsonb_array_length(n->'assigned_crew_ids')>0 ELSE false END) OR n->>'assigned_field_crew_id' IS NOT NULL;
  IF (TG_OP='UPDATE' OR assigned) AND
    (n->'assigned_crew_ids' IS DISTINCT FROM o->'assigned_crew_ids' OR n->'assigned_field_crew_id' IS DISTINCT FROM o->'assigned_field_crew_id') THEN
   PERFORM operational_private.emit('assignment',task,NULL,actor,generation,stamp,'server',concat(task,':assignment:',generation,':',n->>'fc_version'),
    jsonb_build_object('attribution',CASE WHEN actor IS NULL THEN 'not_recorded' ELSE 'authenticated_writer' END,
     'assigned',assigned));
  END IF;
  IF n->>'status' IN ('en_route','in_progress') AND coalesce(o->>'status','') NOT IN ('en_route','in_progress','completed','cancelled') THEN
   PERFORM operational_private.emit('acknowledgement',task,NULL,actor,generation,stamp,'server',concat(task,':ack:',generation),jsonb_build_object('status',n->>'status'));
  END IF;
  IF n->>'status'='completed' AND o->>'status' IS DISTINCT FROM 'completed' THEN
   PERFORM operational_private.emit('completion',task,NULL,coalesce(actor,(n->>'completed_by')::uuid),generation,
    coalesce((n->>'completed_at')::timestamptz,stamp),'server',concat(task,':completion:',generation,':',n->>'fc_version'),jsonb_build_object('outcome',n->>'completion_result'));
   FOR photo IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(receipt->'investigations')='array' THEN receipt->'investigations' ELSE '[]'::jsonb END) LOOP
    report:=NULL;
    IF photo->>'incident_id'=task::text THEN
     IF EXISTS(SELECT 1 FROM public.reports r WHERE r.cleanup_task_id=task) THEN CONTINUE; END IF;
    ELSE
     SELECT r.id INTO report FROM public.reports r WHERE r.id::text=photo->>'incident_id' AND r.cleanup_task_id=task;
     IF report IS NULL THEN CONTINUE; END IF;
    END IF;
    PERFORM operational_private.arrival(photo,task,report,actor,generation,'submitted_with_completion');
   END LOOP;
  END IF;
 ELSE
  report:=NEW.id;task:=(n->>'cleanup_task_id')::uuid;
  SELECT t.assignment_generation INTO generation FROM public.cleanup_tasks t WHERE t.id=task;
  IF n->>'stage'='acknowledged' AND o->>'stage' IS DISTINCT FROM 'acknowledged' THEN
   PERFORM operational_private.emit('acknowledgement',task,report,actor,generation,stamp,'server',concat(report,':ack:',n->>'report_claim_generation'),jsonb_build_object('stage','acknowledged'));
  END IF;
  IF n->>'status' IN ('resolved','completed','waiting_for_feedback') AND coalesce(o->>'status','') NOT IN ('resolved','completed','closed','waiting_for_feedback') THEN
   PERFORM operational_private.emit('completion',task,report,actor,generation,coalesce((n->>'lgu_resolved_at')::timestamptz,stamp),'server',
    concat(report,':completion:',n->>'lgu_resolved_at',':',n->>'fc_version'),jsonb_build_object('status',n->>'status','canonical_time_recorded',n->>'lgu_resolved_at' IS NOT NULL));
  END IF;
 END IF;
 FOREACH slot IN ARRAY ARRAY['before','after'] LOOP
  photos:=coalesce(n->(slot||'_photos'),'[]');previous:=coalesce(o->(slot||'_photos'),'[]');
  IF nullif(n->>(slot||'_photo_url'),'') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(photos) p WHERE p->>'url'=n->>(slot||'_photo_url')) THEN
   photos:=photos||jsonb_build_array(jsonb_build_object('url',n->>(slot||'_photo_url')));
  END IF;
  FOR photo IN SELECT value FROM jsonb_array_elements(photos) LOOP
   IF nullif(photo->>'url','') IS NOT NULL AND photo->>'url' IS DISTINCT FROM o->>(slot||'_photo_url') AND
    NOT EXISTS(SELECT 1 FROM jsonb_array_elements(previous) p WHERE p->>'url'=photo->>'url') THEN
    PERFORM operational_private.emit('evidence_submission',task,CASE WHEN TG_TABLE_NAME='reports' THEN NEW.id END,actor,generation,stamp,'server',
     concat(TG_TABLE_NAME,':',NEW.id,':evidence:',slot,':',photo->>'url'),jsonb_build_object('slot',slot));
   END IF;
  END LOOP;
 END LOOP;
 RETURN NEW;
END; $$;
CREATE TRIGGER operational_task_events AFTER INSERT OR UPDATE ON public.cleanup_tasks FOR EACH ROW EXECUTE FUNCTION operational_private.capture_row();
CREATE TRIGGER operational_report_events AFTER INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION operational_private.capture_row();
CREATE FUNCTION operational_private.capture_receipt() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE receipt jsonb:=coalesce(nullif(current_setting('ecopin.operational_receipt',true),''),'{}')::jsonb;
 generation bigint;
BEGIN
 SELECT ar.assignment_generation INTO generation FROM public.field_assignment_receipts ar WHERE ar.id=NEW.receipt_id;
 PERFORM operational_private.arrival(receipt->'investigation',NEW.task_id,NEW.report_id,NEW.crew_id,generation,NEW.disposition);
 RETURN NEW;
END; $$;
CREATE TRIGGER operational_receipt_arrival AFTER INSERT ON public.task_report_outcomes FOR EACH ROW EXECUTE FUNCTION operational_private.capture_receipt();
CREATE FUNCTION operational_private.capture_verification() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE task uuid; generation bigint;
BEGIN
 SELECT e.task_id,e.assignment_generation INTO task,generation FROM public.operational_events e
 WHERE e.report_id=NEW.report_id AND e.event_type='completion' AND e.occurred_at=NEW.completed_at ORDER BY e.id DESC LIMIT 1;
 IF task IS NULL THEN SELECT r.cleanup_task_id,t.assignment_generation INTO task,generation FROM public.reports r LEFT JOIN public.cleanup_tasks t ON t.id=r.cleanup_task_id WHERE r.id=NEW.report_id; END IF;
 PERFORM operational_private.emit('verification',task,NEW.report_id,NEW.verified_by,generation,NEW.verified_at,'server',
  concat('verification:',NEW.id),jsonb_build_object('publication_id',NEW.id,'source_completed_at',NEW.completed_at));
 RETURN NEW;
END; $$;
CREATE TRIGGER operational_verification AFTER INSERT OR UPDATE ON public.cleanup_proof_publications FOR EACH ROW EXECUTE FUNCTION operational_private.capture_verification();

-- Canonical functions retain their existing authorization, locks and replay behavior.
-- Exact identities prevent duplicate overloads from hiding a missing writer. Fail atomically on drift.
DO $$ DECLARE identity text; target regprocedure; fn record; source text; context_call text; injection text;
BEGIN
 FOREACH identity IN ARRAY ARRAY[
  'public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint)',
  'workflow_private.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint)',
  'public.reconcile_report_outcome(uuid,text,jsonb)',
  'public.submit_task_outcome(uuid,uuid,text,text,text,bigint,text)',
  'public.set_task_photo(uuid,uuid,text,text,text,bigint)',
  'public.set_report_photo(uuid,uuid,text,text,text,bigint)',
  'public.set_report_before_photo(uuid,uuid,text,text,text,bigint)',
  'public.set_report_after_photo(uuid,uuid,text,text,text,bigint)',
  'public.commit_dispatch_plan(uuid,uuid)',
  'public.create_manual_cleanup_task(uuid,uuid[],text,text,uuid[],text)'
 ] LOOP
  target:=to_regprocedure(identity);
  IF target IS NULL THEN RAISE EXCEPTION 'Missing operational writer %',identity USING ERRCODE='42704'; END IF;
  SELECT p.proname,pg_get_function_arguments(p.oid) args,l.lanname INTO fn FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.oid=target;
  IF fn.args !~ '(^|, )actor uuid' OR fn.lanname<>'plpgsql' THEN
   RAISE EXCEPTION 'Unexpected operational actor/function signature %: %',identity,fn.args USING ERRCODE='42804';
  END IF;
  context_call:=CASE WHEN fn.proname IN ('apply_fc_operation','reconcile_report_outcome') THEN 'actor,payload' ELSE 'actor' END;
  IF context_call='actor,payload' AND fn.args !~ '(^|, )payload jsonb' THEN RAISE EXCEPTION 'Unexpected operational function payload %',identity; END IF;
  source:=pg_get_functiondef(target);
  injection:='BEGIN PERFORM operational_private.set_context('||context_call||');';
  -- The isolated patch block can be repeated safely; the enclosing versioned migration is one-shot.
  IF position(injection IN source)>0 THEN CONTINUE; END IF;
  IF source !~* '\mbegin\M' OR position('operational_private.set_context' IN source)>0 THEN RAISE EXCEPTION 'Unexpected operational function body %',identity; END IF;
  source:=regexp_replace(source,'\mbegin\M',injection,'i');
  EXECUTE source;
 END LOOP;
END; $$;
CREATE FUNCTION public.read_operational_events(actor uuid,p_task_id uuid DEFAULT NULL,p_report_id uuid DEFAULT NULL,p_before_id bigint DEFAULT NULL,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')) THEN
  RAISE EXCEPTION 'Desk audit access required' USING ERRCODE='42501';
 END IF;
 IF p_limit IS NULL OR p_limit<1 OR p_limit>100 OR p_before_id<1 THEN RAISE EXCEPTION 'Invalid event page' USING ERRCODE='22023'; END IF;
 RETURN (
 WITH scoped AS NOT MATERIALIZED (
  SELECT e.* FROM public.operational_events e WHERE (p_task_id IS NULL OR e.task_id=p_task_id) AND (p_report_id IS NULL OR e.report_id=p_report_id)
 ), page AS (
  SELECT e.* FROM scoped e WHERE p_before_id IS NULL OR e.id<p_before_id ORDER BY e.id DESC LIMIT p_limit+1
 ), visible AS (SELECT * FROM page ORDER BY id DESC LIMIT p_limit), last_assignment AS (
  SELECT * FROM scoped WHERE event_type='assignment' AND report_id IS NULL ORDER BY id DESC LIMIT 1
 ), milestones AS (
  SELECT a.occurred_at assigned_at,
   min(e.occurred_at) FILTER(WHERE e.event_type='acknowledgement') acknowledged_at,
   min(e.occurred_at) FILTER(WHERE e.event_type='completion') completed_at
  FROM last_assignment a LEFT JOIN scoped e ON e.task_id=a.task_id AND e.report_id IS NULL AND e.assignment_generation=a.assignment_generation AND e.id>=a.id AND e.time_basis='server'
  WHERE coalesce((a.details->>'assigned')::boolean,true) GROUP BY a.occurred_at
 ) SELECT jsonb_build_object(
  'events',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id::text,'event_type',e.event_type,'task_id',e.task_id,'report_id',e.report_id,
   'actor_id',e.actor_id,'assignment_generation',e.assignment_generation,'occurred_at',e.occurred_at,'recorded_at',e.recorded_at,'time_basis',e.time_basis,'details',e.details,
   'completion_to_verification_seconds',CASE WHEN e.event_type='verification' THEN (
    SELECT extract(epoch FROM e.occurred_at-c.occurred_at) FROM public.operational_events c
    WHERE c.event_type='completion' AND c.report_id=e.report_id AND c.occurred_at=(e.details->>'source_completed_at')::timestamptz
     AND c.occurred_at<=e.occurred_at AND c.time_basis='server' ORDER BY c.id DESC LIMIT 1) END) ORDER BY e.id DESC) FROM visible e),'[]'::jsonb),
  'has_more',(SELECT count(*)>p_limit FROM page),
  'next_cursor',CASE WHEN (SELECT count(*)>p_limit FROM page) THEN (SELECT min(id)::text FROM visible) END,
  'server_turnaround',CASE WHEN p_task_id IS NOT NULL AND p_report_id IS NULL THEN coalesce((
   SELECT jsonb_build_object('assignment_to_acknowledgement_seconds',CASE WHEN acknowledged_at>=assigned_at THEN extract(epoch FROM acknowledged_at-assigned_at) END,
    'acknowledgement_to_completion_seconds',CASE WHEN completed_at>=acknowledged_at THEN extract(epoch FROM completed_at-acknowledged_at) END) FROM milestones),
    jsonb_build_object('assignment_to_acknowledgement_seconds',NULL,'acknowledgement_to_completion_seconds',NULL)) END
 )
 );
END; $$;
REVOKE ALL ON FUNCTION public.read_operational_events(uuid,uuid,uuid,bigint,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_operational_events(uuid,uuid,uuid,bigint,integer) TO service_role;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA operational_private FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA operational_private TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
