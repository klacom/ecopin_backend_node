-- PDT-03. Apply after PDT-01/PDT-02 and the lifecycle/outlier-retirement migrations.
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.reports ADD COLUMN urgency_status text CHECK(urgency_status IN ('pending','approved','declined')),
  ADD COLUMN urgency_decision_id uuid, ADD COLUMN urgency_decided_at timestamptz, ADD COLUMN urgency_reason text;
CREATE TABLE public.report_urgency_decisions (
  sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  operation_id uuid PRIMARY KEY,
  report_id uuid NOT NULL,
  actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  outcome text NOT NULL CHECK(outcome IN ('approved','declined')),
  reason text NOT NULL CHECK(char_length(btrim(reason)) BETWEEN 3 AND 1000),
  previous_operation_id uuid REFERENCES public.report_urgency_decisions(operation_id),
  report_context jsonb NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX report_urgency_decisions_latest ON public.report_urgency_decisions(report_id,sequence DESC);
CREATE INDEX reports_urgency_queue ON public.reports(urgency_status,created_at,id) WHERE citizen_priority='urgent';
CREATE TABLE public.report_urgency_alerts (
  report_id uuid NOT NULL,
  recipient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  PRIMARY KEY(report_id,recipient_id)
);
ALTER TABLE public.report_urgency_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.report_urgency_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.report_urgency_decisions,public.report_urgency_alerts FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT ON public.report_urgency_decisions,public.report_urgency_alerts TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.report_urgency_decisions_sequence_seq TO service_role;

CREATE FUNCTION workflow_private.urgency_report_context(r public.reports) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT jsonb_build_object('title',r.title,'description',r.description,
   'location',to_jsonb(r)->'location','issue_type',to_jsonb(r)->'issue_type',
   'severity_score',r.severity_score,'validation_status',r.validation_status,
   'on_private_property',r.on_private_property,'consent',r.property_owner_consent_status,'hazard_class',r.hazard_class);
$$;
CREATE FUNCTION workflow_private.urgency_maturation_bypass(r public.reports) RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT coalesce(r.urgency_status='approved' AND r.validation_status::text='approved'
   AND (NOT coalesce(r.on_private_property,false) OR r.property_owner_consent_status::text='obtained')
   AND coalesce(r.hazard_class,'standard') NOT IN ('suspected_hazard','hazmat_required','hazard_review')
   AND EXISTS(SELECT 1 FROM public.report_urgency_decisions d WHERE d.operation_id=r.urgency_decision_id
     AND d.report_id=r.id AND d.outcome='approved' AND d.report_context=workflow_private.urgency_report_context(r)),false);
$$;

CREATE FUNCTION workflow_private.guard_report_urgency() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE latest public.report_urgency_decisions; plan_settings jsonb; expected text;
BEGIN
  IF TG_OP='INSERT' THEN
    NEW.urgency_status:=CASE WHEN NEW.citizen_priority='urgent' THEN 'pending' END;
    NEW.urgency_decision_id:=NULL; NEW.urgency_decided_at:=NULL; NEW.urgency_reason:=NULL;
    RETURN NEW;
  END IF;
  IF ROW(NEW.urgency_status,NEW.urgency_decision_id,NEW.urgency_decided_at,NEW.urgency_reason)
     IS DISTINCT FROM ROW(OLD.urgency_status,OLD.urgency_decision_id,OLD.urgency_decided_at,OLD.urgency_reason) THEN
    IF current_user NOT IN ('postgres','service_role','supabase_admin') THEN
      RAISE EXCEPTION 'Only the officer urgency service can update a decision.' USING ERRCODE='42501';
    END IF;
    IF OLD.urgency_status IS NULL AND NEW.citizen_priority='urgent' AND NEW.urgency_status='pending'
      AND NEW.urgency_decision_id IS NULL AND NEW.urgency_decided_at IS NULL AND NEW.urgency_reason IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO latest FROM public.report_urgency_decisions WHERE report_id=NEW.id ORDER BY sequence DESC LIMIT 1;
    IF latest.operation_id IS NULL OR NEW.citizen_priority IS DISTINCT FROM 'urgent'
      OR ROW(NEW.urgency_status,NEW.urgency_decision_id,NEW.urgency_decided_at,NEW.urgency_reason)
      IS DISTINCT FROM ROW(latest.outcome,latest.operation_id,latest.recorded_at,latest.reason) THEN
      RAISE EXCEPTION 'Urgency decision must match the latest auditable officer review.' USING ERRCODE='42501';
    END IF;
  END IF;
  -- Focused plans snapshot approvals. A changed/withdrawn approval cannot commit an old draft.
  IF NEW.cleanup_task_id IS NOT NULL AND NEW.cleanup_task_id IS DISTINCT FROM OLD.cleanup_task_id THEN
    SELECT p.settings_snapshot INTO plan_settings FROM public.cleanup_tasks t JOIN public.dispatch_plans p ON p.id=t.source_plan_id WHERE t.id=NEW.cleanup_task_id;
    expected:=plan_settings->'urgency_decisions'->>NEW.id::text;
    IF expected IS NOT NULL AND (NEW.urgency_decision_id::text IS DISTINCT FROM expected OR NOT workflow_private.urgency_maturation_bypass(NEW)) THEN
      RAISE EXCEPTION 'stale_group' USING ERRCODE='P0001',DETAIL='Urgency changed; generate a new dispatch plan.';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER a_guard_report_urgency BEFORE INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_report_urgency();

CREATE FUNCTION workflow_private.notify_urgent_report() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
  IF NEW.urgency_status='pending' AND NEW.user_id IS NOT NULL AND NEW.status::text='unresolved'
    AND NEW.cleanup_task_id IS NULL AND NEW.validation_status::text<>'rejected'
    AND (TG_OP='INSERT' OR OLD.urgency_status IS NULL) THEN
    WITH recipients AS (
      INSERT INTO public.report_urgency_alerts(report_id,recipient_id)
      SELECT NEW.id,p.id FROM public.profiles p WHERE p.role::text IN ('officer','admin') AND p.id<>NEW.user_id
      ON CONFLICT DO NOTHING RETURNING recipient_id
    )
    INSERT INTO public.notifications(user_id,report_id,type,title,body,is_read)
      SELECT recipient_id,NEW.id,'general','Urgent report awaiting verification',
        'A citizen requested urgent review. Verify the report in the Urgent verification queue before dispatch.',false FROM recipients;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER urgent_report_notification AFTER INSERT OR UPDATE OF urgency_status ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.notify_urgent_report();

-- Enrich the existing Mixed snapshot within one database statement/snapshot.
ALTER FUNCTION public.mixed_planning_snapshot() SET SCHEMA workflow_private;
CREATE FUNCTION public.mixed_planning_snapshot() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT payload||jsonb_build_object('urgency_decisions',coalesce((
   SELECT jsonb_object_agg(r.id::text,r.urgency_decision_id::text) FROM public.reports r
   WHERE r.urgency_status='approved' AND r.urgency_decision_id IS NOT NULL AND r.id IN (
     SELECT member.value::uuid FROM jsonb_array_elements(payload->'anchors') a(value) CROSS JOIN LATERAL jsonb_array_elements_text(a.value->'report_ids') member(value)
     UNION SELECT (s.value->>'id')::uuid FROM jsonb_array_elements(payload->'satellites') s(value)
   )), '{}'::jsonb))
 FROM workflow_private.mixed_planning_snapshot() AS payload;
$$;
REVOKE ALL ON FUNCTION public.mixed_planning_snapshot(),workflow_private.mixed_planning_snapshot() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.mixed_planning_snapshot(),workflow_private.mixed_planning_snapshot() TO service_role;

CREATE FUNCTION public.record_report_urgency_decision(actor uuid,report_id uuid,outcome text,reason text,operation_id uuid,expected_decision_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.reports; prior public.report_urgency_decisions; saved public.report_urgency_decisions; actor_role text; normalized text:=btrim(reason);
BEGIN
  SELECT * INTO r FROM public.reports WHERE id=report_id FOR UPDATE;
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
  IF actor_role IS NULL OR actor_role NOT IN ('officer','admin') THEN RAISE EXCEPTION 'Desk officer access required.' USING ERRCODE='42501'; END IF;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Report not found.' USING ERRCODE='P0002'; END IF;
  IF r.user_id=actor THEN RAISE EXCEPTION 'You cannot verify urgency on your own report.' USING ERRCODE='42501'; END IF;
  IF outcome IS NULL OR outcome NOT IN ('approved','declined') OR operation_id IS NULL OR normalized IS NULL OR char_length(normalized) NOT BETWEEN 3 AND 1000 THEN
    RAISE EXCEPTION 'Choose an urgency outcome and provide a reason (3-1000 characters).' USING ERRCODE='22023';
  END IF;
  SELECT * INTO prior FROM public.report_urgency_decisions d WHERE d.operation_id=record_report_urgency_decision.operation_id;
  IF prior.operation_id IS NOT NULL THEN
    IF ROW(prior.report_id,prior.actor_id,prior.outcome,prior.reason,prior.previous_operation_id)
      IS DISTINCT FROM ROW(report_id,actor,outcome,normalized,expected_decision_id) THEN
      RAISE EXCEPTION 'Urgency operation conflict; use a new operation ID.' USING ERRCODE='23505';
    END IF;
    IF r.urgency_decision_id IS DISTINCT FROM prior.operation_id THEN
      RAISE EXCEPTION 'Urgency decision was superseded; refresh before reviewing.' USING ERRCODE='23505';
    END IF;
    RETURN to_jsonb(r);
  END IF;
  IF r.citizen_priority IS DISTINCT FROM 'urgent' OR r.urgency_status IS NULL OR r.user_id IS NULL
    OR r.status::text<>'unresolved' OR r.cleanup_task_id IS NOT NULL OR r.validation_status::text='rejected' THEN
    RAISE EXCEPTION 'Report is not actionable, is closed/rejected, or is already assigned.' USING ERRCODE='23505';
  END IF;
  IF r.urgency_decision_id IS DISTINCT FROM expected_decision_id THEN RAISE EXCEPTION 'Urgency decision conflict; refresh before reviewing.' USING ERRCODE='23505'; END IF;
  IF outcome='approved' THEN
    IF r.validation_status::text IS DISTINCT FROM 'approved' THEN RAISE EXCEPTION 'Approve report validation before urgency.' USING ERRCODE='22023'; END IF;
    IF coalesce(r.on_private_property,false) AND r.property_owner_consent_status::text IS DISTINCT FROM 'obtained' THEN RAISE EXCEPTION 'Property consent is required before approval.' USING ERRCODE='22023'; END IF;
    IF coalesce(r.hazard_class,'standard') IN ('suspected_hazard','hazmat_required','hazard_review') THEN RAISE EXCEPTION 'Complete safety review before urgency approval.' USING ERRCODE='22023'; END IF;
    IF r.sla_started_at IS NULL THEN RAISE EXCEPTION 'Report lifecycle must be activated before urgency approval.' USING ERRCODE='22023'; END IF;
  END IF;
  INSERT INTO public.report_urgency_decisions(operation_id,report_id,actor_id,outcome,reason,previous_operation_id,report_context)
    VALUES(operation_id,report_id,actor,outcome,normalized,expected_decision_id,workflow_private.urgency_report_context(r)) RETURNING * INTO saved;
  UPDATE public.reports SET urgency_status=outcome,urgency_decision_id=operation_id,urgency_decided_at=saved.recorded_at,urgency_reason=normalized,updated_at=clock_timestamp()
    WHERE id=report_id RETURNING * INTO r;
  RETURN to_jsonb(r);
END $$;

CREATE FUNCTION public.read_report_urgency_queue(actor uuid,queue_status text DEFAULT 'pending',page_limit integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE actor_role text; result jsonb; total integer;
BEGIN
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor;
  IF actor_role IS NULL OR actor_role NOT IN ('officer','admin') THEN RAISE EXCEPTION 'Desk officer access required.' USING ERRCODE='42501'; END IF;
  IF queue_status IS NULL OR queue_status NOT IN ('pending','approved','declined') OR page_limit IS NULL OR page_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Invalid urgency queue filter or limit.' USING ERRCODE='22023';
  END IF;
  SELECT count(*) INTO total FROM public.reports r WHERE r.citizen_priority='urgent' AND (CASE WHEN r.urgency_status='approved' AND NOT workflow_private.urgency_maturation_bypass(r) THEN 'pending' ELSE r.urgency_status END)=queue_status
    AND r.user_id IS NOT NULL AND r.status::text='unresolved' AND r.cleanup_task_id IS NULL AND r.validation_status::text<>'rejected';
  SELECT coalesce(jsonb_agg(q ORDER BY q.created_at,q.id),'[]'::jsonb) INTO result FROM (
    SELECT r.id,r.title,r.description,r.created_at,r.priority_reason,r.priority_explanation,r.validation_status,
      r.on_private_property,r.property_owner_consent_status,r.hazard_class,r.cluster_id,r.lifecycle_state,
      r.urgency_status,r.urgency_decision_id,r.urgency_decided_at,r.urgency_reason,r.sla_started_at,
      r.user_id<>actor AS review_allowed,
      r.urgency_status='approved' AND NOT workflow_private.urgency_maturation_bypass(r) AS needs_reverification,
      workflow_private.urgency_maturation_bypass(r) AND r.lifecycle_state IN ('maturing','sla_breached','clustered')
        AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE (b.report_id=r.id OR b.cluster_id=r.cluster_id) AND b.cleared_at IS NULL)
        AND (r.cluster_id IS NULL OR (
          EXISTS(SELECT 1 FROM public.clusters c WHERE c.id=r.cluster_id AND c.status::text IN ('new','unresolved','prioritized','queued','monitoring'))
          AND NOT EXISTS(SELECT 1 FROM public.reports sibling WHERE sibling.cluster_id=r.cluster_id
            AND sibling.status::text NOT IN ('resolved','completed','closed','rejected')
            AND (sibling.cleanup_task_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=sibling.id AND b.cleared_at IS NULL)))
        )) AS dispatchable
    FROM public.reports r WHERE r.citizen_priority='urgent' AND (CASE WHEN r.urgency_status='approved' AND NOT workflow_private.urgency_maturation_bypass(r) THEN 'pending' ELSE r.urgency_status END)=queue_status AND r.user_id IS NOT NULL
      AND r.status::text='unresolved' AND r.cleanup_task_id IS NULL AND r.validation_status::text<>'rejected'
    ORDER BY r.created_at,r.id LIMIT page_limit
  ) q;
  RETURN jsonb_build_object('reports',result,'total',total,'limit',page_limit);
END $$;

-- Preserve the lifecycle clock/history; only the effective maturation threshold changes.
CREATE OR REPLACE FUNCTION workflow_private.apply_report_lifecycle() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE deployed timestamptz; cfg record; maturation numeric; bypass boolean; stamp timestamptz:=statement_timestamp();
BEGIN
  SELECT activated_at INTO deployed FROM workflow_private.lifecycle_deployment WHERE singleton;
  IF deployed IS NULL THEN NEW.sla_started_at:=NULL; NEW.lifecycle_state:=NULL; NEW.matured_at:=NULL; NEW.breached_at:=NULL; RETURN NEW; END IF;
  SELECT * INTO cfg FROM workflow_private.lifecycle_config();
  bypass:=workflow_private.urgency_maturation_bypass(NEW);
  maturation:=CASE WHEN bypass THEN 0 WHEN workflow_private.severity_tier(NEW.severity_score)='high' THEN cfg.high_hours ELSE cfg.normal_hours END;
  IF TG_OP='INSERT' THEN
    NEW.sla_started_at:=stamp; NEW.deadline_at:=stamp+cfg.sla_hours*interval '1 hour'; NEW.matured_at:=NULL; NEW.breached_at:=NULL;
  ELSE
    NEW.sla_started_at:=coalesce(OLD.sla_started_at,CASE WHEN OLD.status::text='unresolved' THEN deployed ELSE coalesce(OLD.created_at,deployed) END);
    NEW.deadline_at:=CASE WHEN OLD.sla_started_at IS NOT NULL THEN OLD.deadline_at WHEN OLD.status::text='unresolved' THEN deployed+cfg.sla_hours*interval '1 hour'
      ELSE coalesce(OLD.deadline_at,NEW.sla_started_at+cfg.sla_hours*interval '1 hour') END;
    -- First observed eligibility and breach are historical; current eligibility is lifecycle_state.
    NEW.matured_at:=OLD.matured_at; NEW.breached_at:=OLD.breached_at;
  END IF;
  -- Include closure transitions so closing an overdue report cannot erase the elapsed breach.
  IF TG_OP='INSERT' OR coalesce(OLD.status::text,'unresolved') NOT IN ('resolved','completed','closed','rejected') THEN
    IF stamp>=NEW.sla_started_at+maturation*interval '1 hour' THEN
      NEW.matured_at:=coalesce(NEW.matured_at,CASE WHEN bypass THEN NEW.urgency_decided_at ELSE NEW.sla_started_at+maturation*interval '1 hour' END);
    END IF;
    IF stamp>=NEW.deadline_at THEN NEW.breached_at:=coalesce(NEW.breached_at,NEW.deadline_at); END IF;
  END IF;
  NEW.lifecycle_state:=workflow_private.derive_report_lifecycle(NEW.status::text,NEW.cluster_id,NEW.cleanup_task_id,NEW.sla_started_at,NEW.deadline_at,maturation,stamp);
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.advance_report_lifecycle() RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE cfg record; changed integer; breaches jsonb;
BEGIN
  IF NOT pg_catalog.pg_try_advisory_xact_lock(72631008) THEN RETURN jsonb_build_object('skipped',true,'changedCount',0,'newlyBreached','[]'::jsonb); END IF;
  IF NOT EXISTS(SELECT 1 FROM workflow_private.lifecycle_deployment) THEN RAISE EXCEPTION 'Report lifecycle has not been activated'; END IF;
  SELECT * INTO cfg FROM workflow_private.lifecycle_config();
  WITH candidates AS MATERIALIZED (
    SELECT r.id,r.breached_at AS old_breached FROM public.reports r
    WHERE r.lifecycle_state IS DISTINCT FROM 'closed' AND (
      r.lifecycle_state IS DISTINCT FROM workflow_private.derive_report_lifecycle(r.status::text,r.cluster_id,r.cleanup_task_id,r.sla_started_at,r.deadline_at,
        CASE WHEN workflow_private.urgency_maturation_bypass(r) THEN 0 WHEN workflow_private.severity_tier(r.severity_score)='high' THEN cfg.high_hours ELSE cfg.normal_hours END,statement_timestamp())
      OR (r.breached_at IS NULL AND statement_timestamp()>=r.deadline_at)
      OR (r.matured_at IS NULL AND statement_timestamp()>=r.sla_started_at+
        (CASE WHEN workflow_private.urgency_maturation_bypass(r) THEN 0 WHEN workflow_private.severity_tier(r.severity_score)='high' THEN cfg.high_hours ELSE cfg.normal_hours END)*interval '1 hour'))
    FOR UPDATE SKIP LOCKED
  ),updated AS (
    UPDATE public.reports r SET updated_at=statement_timestamp() FROM candidates c WHERE r.id=c.id RETURNING r.id,r.breached_at,c.old_breached,r.sla_started_at
  ) SELECT count(*)::integer,coalesce(jsonb_agg(jsonb_build_object('id',u.id,'breachDuration',extract(epoch FROM(statement_timestamp()-u.sla_started_at))/3600,'timestamp',u.breached_at))
      FILTER(WHERE u.old_breached IS NULL AND u.breached_at IS NOT NULL),'[]'::jsonb) INTO changed,breaches FROM updated u;
  INSERT INTO public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data) VALUES('LIFECYCLE_RUN_COMPLETED','SYSTEM','report_lifecycle','system',
    jsonb_build_object('changedCount',changed,'newlyBreachedCount',jsonb_array_length(breaches)));
  RETURN jsonb_build_object('skipped',false,'changedCount',changed,'newlyBreached',breaches);
END $$;

REVOKE ALL ON FUNCTION workflow_private.urgency_report_context(public.reports),workflow_private.urgency_maturation_bypass(public.reports),
  workflow_private.guard_report_urgency(),workflow_private.notify_urgent_report(),
  public.advance_report_lifecycle(),public.record_report_urgency_decision(uuid,uuid,text,text,uuid,uuid),public.read_report_urgency_queue(uuid,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.urgency_report_context(public.reports),workflow_private.urgency_maturation_bypass(public.reports),
  workflow_private.guard_report_urgency(),workflow_private.notify_urgent_report(),
  public.advance_report_lifecycle(),public.record_report_urgency_decision(uuid,uuid,text,text,uuid,uuid),public.read_report_urgency_queue(uuid,text,integer) TO service_role;
UPDATE public.reports SET urgency_status='pending' WHERE citizen_priority='urgent' AND urgency_status IS NULL
  AND user_id IS NOT NULL AND status::text='unresolved' AND cleanup_task_id IS NULL AND validation_status::text<>'rejected';
NOTIFY pgrst,'reload schema';
COMMIT;
