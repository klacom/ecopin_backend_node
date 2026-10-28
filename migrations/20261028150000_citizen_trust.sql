-- PDT-02. Requires add_citizen_report_priority.sql. All trust writes are server-only.
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE TABLE public.citizen_trust (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  score integer NOT NULL DEFAULT 50 CHECK (score BETWEEN 0 AND 100),
  recovery_streak integer NOT NULL DEFAULT 0 CHECK (recovery_streak BETWEEN 0 AND 3),
  locked_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.citizen_trust_decisions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation_id uuid NOT NULL UNIQUE,
  report_id uuid NOT NULL,
  user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  outcome text NOT NULL CHECK (outcome IN ('valid','neutral','false_urgency','withdrawn')),
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 3 AND 1000),
  submitted_priority text,
  supersedes_id bigint UNIQUE REFERENCES public.citizen_trust_decisions(id),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX citizen_trust_one_initial_review ON public.citizen_trust_decisions(report_id) WHERE supersedes_id IS NULL;
CREATE INDEX citizen_trust_decisions_owner ON public.citizen_trust_decisions(user_id,id);
CREATE INDEX citizen_trust_decisions_report_latest ON public.citizen_trust_decisions(report_id,id DESC);
-- Preserve review history when a report is withdrawn; profile deletion anonymizes it.
ALTER TABLE public.citizen_trust ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.citizen_trust_decisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.citizen_trust, public.citizen_trust_decisions FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.citizen_trust, public.citizen_trust_decisions FROM service_role;
GRANT SELECT,INSERT,UPDATE ON public.citizen_trust TO service_role;
GRANT SELECT,INSERT ON public.citizen_trust_decisions TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.citizen_trust_decisions_id_seq TO service_role;

ALTER TABLE public.reports ADD COLUMN submitted_citizen_priority text;
UPDATE public.reports SET submitted_citizen_priority=citizen_priority WHERE citizen_priority IS NOT NULL;

CREATE FUNCTION public.ensure_citizen_trust(target uuid) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=target AND role::text='citizen') THEN
    RAISE EXCEPTION 'Citizen trust is available only for citizen accounts.' USING ERRCODE='42501';
  END IF;
  INSERT INTO public.citizen_trust(user_id) VALUES(target) ON CONFLICT DO NOTHING;
END $$;

CREATE FUNCTION public.citizen_trust_snapshot(target uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE s public.citizen_trust; t timestamptz := clock_timestamp();
BEGIN
  PERFORM public.ensure_citizen_trust(target);
  SELECT * INTO STRICT s FROM public.citizen_trust WHERE user_id=target;
  RETURN jsonb_build_object('score',s.score,'score_threshold',70,'max_score',100,
    'urgent_allowed',s.score>=70 AND (s.locked_until IS NULL OR (s.locked_until<=t AND s.recovery_streak>=3)),
    'locked_until',s.locked_until,'recovery_reports_remaining',CASE WHEN s.locked_until IS NULL THEN 0 ELSE 3-s.recovery_streak END,
    'valid_report_points',10,'false_urgency_penalty',30,'cooldown_days',7,'server_time',t);
END $$;

CREATE FUNCTION public.rebuild_citizen_trust(target uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE points integer := 50; streak integer := 0; deadline timestamptz; e record;
BEGIN
  PERFORM public.ensure_citizen_trust(target);
  PERFORM 1 FROM public.citizen_trust WHERE user_id=target FOR UPDATE;
  FOR e IN SELECT d.* FROM public.citizen_trust_decisions d
    WHERE d.user_id=target AND NOT EXISTS(SELECT 1 FROM public.citizen_trust_decisions newer WHERE newer.supersedes_id=d.id)
    ORDER BY d.id
  LOOP
    IF e.outcome='false_urgency' THEN
      points:=greatest(0,points-30); streak:=0; deadline:=e.recorded_at+interval '168 hours';
    ELSIF e.outcome='valid' THEN
      points:=least(100,points+10);
      IF deadline IS NOT NULL THEN streak:=least(3,streak+1); END IF;
    ELSIF e.outcome='neutral' AND streak<3 THEN
      streak:=0;
    END IF;
  END LOOP;
  UPDATE public.citizen_trust SET score=points,recovery_streak=streak,locked_until=deadline,updated_at=clock_timestamp() WHERE user_id=target;
  RETURN public.citizen_trust_snapshot(target);
END $$;

-- Locks permissions through commit. Lock order: report -> actor/task/team -> trust.
CREATE FUNCTION public.authorize_citizen_trust_review(actor uuid, report_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.reports; actor_role text; task public.cleanup_tasks; crew public.field_crews;
BEGIN
  SELECT * INTO r FROM public.reports WHERE id=report_id FOR SHARE;
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
  IF r.id IS NULL OR r.user_id IS NULL OR r.user_id=actor THEN
    RAISE EXCEPTION 'Not authorized to review this report or your own report.' USING ERRCODE='42501';
  END IF;
  IF actor_role IN ('officer','admin') THEN RETURN; END IF;
  IF actor_role='field_crew' THEN
    SELECT * INTO task FROM public.cleanup_tasks WHERE id=r.cleanup_task_id FOR SHARE;
    IF task.route_status='ready' AND task.status::text IN ('created','pending','assigned','en_route','in_progress','partially_completed') THEN
      IF actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])) THEN RETURN; END IF;
      SELECT * INTO crew FROM public.field_crews WHERE id=task.assigned_field_crew_id FOR SHARE;
      IF crew.team_lead_profile_id=actor OR actor=ANY(coalesce(crew.member_profile_ids,'{}'::uuid[])) THEN RETURN; END IF;
    END IF;
  END IF;
  RAISE EXCEPTION 'Only SWMO or assigned crew may review this report.' USING ERRCODE='42501';
END $$;

CREATE FUNCTION public.read_citizen_trust_review(actor uuid, report_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.reports; decision public.citizen_trust_decisions; actor_role text; citizen boolean;
BEGIN
  SELECT * INTO r FROM public.reports WHERE id=report_id FOR SHARE;
  SELECT * INTO decision FROM public.citizen_trust_decisions d WHERE d.report_id=read_citizen_trust_review.report_id ORDER BY id DESC LIMIT 1;
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
  IF (r.id IS NULL OR r.user_id IS NULL) AND actor_role='admin' AND decision.id IS NOT NULL AND decision.user_id IS DISTINCT FROM actor THEN
    r.submitted_citizen_priority:=decision.submitted_priority;
  ELSE
    PERFORM public.authorize_citizen_trust_review(actor,report_id);
  END IF;
  citizen:=EXISTS(SELECT 1 FROM public.profiles WHERE id=r.user_id AND role::text='citizen');
  RETURN jsonb_build_object('reviewable',citizen,'submitted_priority',r.submitted_citizen_priority,'priority_reason',r.priority_reason,
    'priority_explanation',r.priority_explanation,'decision',CASE WHEN decision.id IS NULL THEN NULL ELSE to_jsonb(decision)-'user_id'-'actor_id'-'operation_id' END);
END $$;

CREATE FUNCTION public.record_citizen_trust_review(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.reports; prior public.citizen_trust_decisions; retry public.citizen_trust_decisions;
  saved public.citizen_trust_decisions; actor_role text; normalized_reason text := btrim(reason);
BEGIN
  IF operation_id IS NULL OR outcome IS NULL OR outcome NOT IN ('valid','neutral','false_urgency','withdrawn')
    OR normalized_reason IS NULL OR char_length(normalized_reason) NOT BETWEEN 3 AND 1000 THEN
    RAISE EXCEPTION 'Choose a review outcome and give a reason (3-1000 characters).' USING ERRCODE='22023';
  END IF;
  SELECT * INTO r FROM public.reports WHERE id=report_id FOR UPDATE;
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
  IF (r.id IS NULL OR r.user_id IS NULL) AND expected_decision_id IS NOT NULL AND actor_role='admin' THEN
    -- Deleted/anonymized reports must not strand an erroneous penalty.
    SELECT * INTO prior FROM public.citizen_trust_decisions d WHERE d.report_id=record_citizen_trust_review.report_id ORDER BY id DESC LIMIT 1;
    IF prior.user_id IS NULL OR prior.user_id=actor THEN
      RAISE EXCEPTION 'Not authorized to correct this trust review.' USING ERRCODE='42501';
    END IF;
    r.user_id:=prior.user_id; r.submitted_citizen_priority:=prior.submitted_priority;
  ELSE
    PERFORM public.authorize_citizen_trust_review(actor,report_id);
  END IF;
  IF (expected_decision_id IS NOT NULL OR outcome='withdrawn') AND actor_role<>'admin' THEN
    RAISE EXCEPTION 'Only an administrator may correct a trust review.' USING ERRCODE='42501';
  END IF;
  IF outcome='false_urgency' AND r.submitted_citizen_priority IS DISTINCT FROM 'urgent' THEN
    RAISE EXCEPTION 'A false urgency finding requires an originally Urgent report.' USING ERRCODE='22023';
  END IF;
  PERFORM public.ensure_citizen_trust(r.user_id);
  PERFORM 1 FROM public.citizen_trust WHERE user_id=r.user_id FOR UPDATE;
  SELECT * INTO retry FROM public.citizen_trust_decisions d WHERE d.operation_id=record_citizen_trust_review.operation_id;
  IF retry.id IS NOT NULL THEN
    IF retry.report_id IS DISTINCT FROM report_id OR retry.actor_id IS DISTINCT FROM actor OR retry.outcome IS DISTINCT FROM outcome
      OR retry.reason IS DISTINCT FROM normalized_reason OR retry.supersedes_id IS DISTINCT FROM expected_decision_id THEN
      RAISE EXCEPTION 'Review operation conflict; use a new operation ID.' USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object('decision',to_jsonb(retry)-'user_id'-'actor_id'-'operation_id','trust',public.citizen_trust_snapshot(r.user_id));
  END IF;
  SELECT * INTO prior FROM public.citizen_trust_decisions d WHERE d.report_id=record_citizen_trust_review.report_id ORDER BY id DESC LIMIT 1;
  IF prior.id IS NOT NULL AND expected_decision_id IS NULL THEN
    IF prior.supersedes_id IS NULL AND prior.actor_id=actor AND prior.outcome=outcome AND prior.reason=normalized_reason THEN
      RETURN jsonb_build_object('decision',to_jsonb(prior)-'user_id'-'actor_id'-'operation_id','trust',public.citizen_trust_snapshot(r.user_id));
    END IF;
    RAISE EXCEPTION 'Report already reviewed; an administrator must correct it.' USING ERRCODE='23505';
  END IF;
  IF expected_decision_id IS DISTINCT FROM prior.id OR (prior.id IS NULL AND outcome='withdrawn') THEN
    RAISE EXCEPTION 'Review conflict; refresh before correcting this decision.' USING ERRCODE='23505';
  END IF;
  INSERT INTO public.citizen_trust_decisions(operation_id,report_id,user_id,actor_id,outcome,reason,submitted_priority,supersedes_id)
    VALUES(operation_id,report_id,r.user_id,actor,outcome,normalized_reason,r.submitted_citizen_priority,expected_decision_id)
    RETURNING * INTO saved;
  RETURN jsonb_build_object('decision',to_jsonb(saved)-'user_id'-'actor_id'-'operation_id','trust',public.rebuild_citizen_trust(r.user_id));
END $$;

CREATE FUNCTION public.gate_citizen_urgent_report() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE allowed boolean;
BEGIN
  IF TG_OP='INSERT' THEN
    NEW.submitted_citizen_priority:=NEW.citizen_priority;
  ELSE
    IF NEW.submitted_citizen_priority IS DISTINCT FROM OLD.submitted_citizen_priority THEN
      RAISE EXCEPTION 'Submitted citizen priority is immutable.' USING ERRCODE='22023';
    END IF;
    IF NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NOT NULL THEN
      RAISE EXCEPTION 'The report owner cannot be reassigned.' USING ERRCODE='22023';
    END IF;
    IF NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NULL AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
      RAISE EXCEPTION 'Only account administration may anonymize a report.' USING ERRCODE='42501';
    END IF;
    -- Existing urgent reports keep normal edits; account deletion may anonymize them.
    IF NEW.citizen_priority IS NOT DISTINCT FROM OLD.citizen_priority THEN RETURN NEW; END IF;
    -- Submitted priority is immutable: changing citizen intent after submission needs a separate request.
    RAISE EXCEPTION 'Submitted citizen priority is immutable.' USING ERRCODE='22023';
  END IF;
  IF NEW.citizen_priority IS DISTINCT FROM 'urgent' THEN RETURN NEW; END IF;
  PERFORM public.ensure_citizen_trust(NEW.user_id);
  PERFORM 1 FROM public.citizen_trust WHERE user_id=NEW.user_id FOR UPDATE;
  allowed:=(public.citizen_trust_snapshot(NEW.user_id)->>'urgent_allowed')::boolean;
  IF NOT allowed THEN
    RAISE EXCEPTION 'Urgent is locked. Check your trust score and recovery requirements in Profile. You can still submit Non-urgent reports.' USING ERRCODE='P0001',HINT='URGENT_TRUST_LOCKED';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER citizen_urgent_gate BEFORE INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION public.gate_citizen_urgent_report();

REVOKE ALL ON FUNCTION public.ensure_citizen_trust(uuid),public.citizen_trust_snapshot(uuid),public.rebuild_citizen_trust(uuid),
  public.authorize_citizen_trust_review(uuid,uuid),public.read_citizen_trust_review(uuid,uuid),
  public.record_citizen_trust_review(uuid,uuid,text,text,uuid,bigint),public.gate_citizen_urgent_report() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_citizen_trust(uuid),public.citizen_trust_snapshot(uuid),public.rebuild_citizen_trust(uuid),
  public.authorize_citizen_trust_review(uuid,uuid),public.read_citizen_trust_review(uuid,uuid),
  public.record_citizen_trust_review(uuid,uuid,text,text,uuid,bigint),public.gate_citizen_urgent_report() TO service_role;
COMMIT;
