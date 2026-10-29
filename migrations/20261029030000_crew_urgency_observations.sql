-- PDT-04. Requires PDT-01/02, canonical field sync and crew photo collections.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.crew_urgency_observations (
  operation_id text PRIMARY KEY,
  report_id uuid NOT NULL,
  task_id uuid NOT NULL,
  actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  observed_result text NOT NULL CHECK(observed_result IN ('urgent_observed','conditions_differ','unable_to_verify')),
  conditions text NOT NULL CHECK(char_length(conditions) BETWEEN 3 AND 1500),
  evidence_snapshot jsonb NOT NULL,
  note_id text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX crew_urgency_by_report ON public.crew_urgency_observations(report_id,recorded_at DESC);
CREATE TABLE public.crew_urgency_reviews (
  observation_id text PRIMARY KEY REFERENCES public.crew_urgency_observations(operation_id),
  operation_id uuid NOT NULL UNIQUE,
  actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reason text NOT NULL CHECK(char_length(reason) BETWEEN 3 AND 1500),
  reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.crew_urgency_observations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crew_urgency_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.crew_urgency_observations,public.crew_urgency_reviews FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT ON public.crew_urgency_observations,public.crew_urgency_reviews TO service_role;

-- Crew observations never score citizens; explicit trust decisions now belong to desk staff.
CREATE OR REPLACE FUNCTION public.authorize_citizen_trust_review(actor uuid,report_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.reports; actor_role text;
BEGIN
 SELECT * INTO r FROM public.reports WHERE id=report_id FOR SHARE;
 SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
 IF r.id IS NULL OR r.user_id IS NULL OR r.user_id=actor OR actor_role IS NULL OR actor_role NOT IN ('officer','admin') THEN
  RAISE EXCEPTION 'Only SWMO officers/admins may make citizen trust decisions; crew submit observations for review.' USING ERRCODE='42501';
 END IF;
END $$;

-- Preserve ordinary sync operations and canonical receipts; structured notes add a non-scoring record.
ALTER FUNCTION public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint) SET SCHEMA workflow_private;
CREATE FUNCTION public.apply_fc_operation(actor uuid,operation_id text,operation_type text,entity_id uuid,entity_type text,payload jsonb,base_version bigint DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE observation jsonb:=payload->'urgency_observation'; canonical jsonb; result jsonb;
 r public.reports; t public.cleanup_tasks; role_name text; saved public.crew_urgency_observations; label text;
BEGIN
 IF NOT coalesce(payload ? 'urgency_observation',false) THEN
  RETURN workflow_private.apply_fc_operation(actor,operation_id,operation_type,entity_id,entity_type,payload,base_version);
 END IF;
 IF operation_type IS DISTINCT FROM 'fc.note.add' OR entity_type IS DISTINCT FROM 'report' OR jsonb_typeof(observation) IS DISTINCT FROM 'object'
   OR jsonb_typeof(observation->'conditions') IS DISTINCT FROM 'string'
   OR char_length(btrim(observation->>'conditions')) NOT BETWEEN 3 AND 1500
   OR observation->>'result' IS NULL OR observation->>'result' NOT IN ('urgent_observed','conditions_differ','unable_to_verify')
   OR coalesce(observation->>'task_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   OR coalesce(observation->>'assignment_generation','') !~ '^[0-9]{1,15}$'
   OR coalesce(observation->>'report_claim_generation','') !~ '^[0-9]{1,15}$' THEN
  RAISE EXCEPTION 'Provide task receipt, observed urgency and conditions (3-1500 characters).' USING ERRCODE='22023';
 END IF;
 IF observation->>'observer_id' IS DISTINCT FROM actor::text THEN RAISE EXCEPTION 'Observation belongs to another signed-in crew member.' USING ERRCODE='42501'; END IF;
 label:=CASE observation->>'result' WHEN 'urgent_observed' THEN 'Urgency observed' WHEN 'conditions_differ' THEN 'Conditions differ' ELSE 'Unable to verify' END;
 canonical:=payload||jsonb_build_object('action','On-site urgency: '||label||'. '||btrim(observation->>'conditions')||' [For officer review; no automatic trust change.]');
 -- The underlying transaction serializes operation IDs and locks task -> report.
 result:=workflow_private.apply_fc_operation(actor,operation_id,operation_type,entity_id,entity_type,canonical,base_version);
 SELECT * INTO saved FROM public.crew_urgency_observations o WHERE o.operation_id=apply_fc_operation.operation_id;
 IF saved.operation_id IS NOT NULL THEN RETURN result; END IF;
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor FOR SHARE;
 SELECT * INTO r FROM public.reports WHERE id=entity_id;
 SELECT * INTO t FROM public.cleanup_tasks WHERE id=r.cleanup_task_id;
 IF role_name IS DISTINCT FROM 'field_crew' OR r.user_id=actor OR r.citizen_priority IS DISTINCT FROM 'urgent'
   OR r.cleanup_task_id IS DISTINCT FROM (observation->>'task_id')::uuid OR t.id IS NULL
   OR t.status::text NOT IN ('created','pending','assigned','en_route','in_progress','partially_completed')
   OR t.route_status IS DISTINCT FROM 'ready' OR NOT coalesce(workflow_private.can_execute_task(actor,t),false)
   OR (to_jsonb(t)->>'assignment_generation')::bigint IS DISTINCT FROM (observation->>'assignment_generation')::bigint
   OR (to_jsonb(r)->>'report_claim_generation')::bigint IS DISTINCT FROM (observation->>'report_claim_generation')::bigint
   OR result->>'status' IS DISTINCT FROM 'success' THEN
  RAISE EXCEPTION 'Observation requires your current active assignment to an Urgent report. Refresh the task receipt.' USING ERRCODE='42501';
 END IF;
 INSERT INTO public.crew_urgency_observations(operation_id,report_id,task_id,actor_id,observed_result,conditions,evidence_snapshot,note_id)
 VALUES(operation_id,entity_id,t.id,actor,observation->>'result',btrim(observation->>'conditions'),
  jsonb_build_object('before_photos',coalesce(to_jsonb(r)->'before_photos','[]'::jsonb),'after_photos',coalesce(to_jsonb(r)->'after_photos','[]'::jsonb),
    'before_photo_url',to_jsonb(r)->'before_photo_url','after_photo_url',to_jsonb(r)->'after_photo_url'),result->'server_record'->>'id');
 INSERT INTO public.notifications(user_id,report_id,type,title,body,is_read)
 SELECT p.id,r.id,'general','Crew urgency observation awaiting review','Review on-site conditions and evidence in Report Details. No trust score has been changed.',false
 FROM public.profiles p WHERE p.role::text IN ('officer','admin') AND p.id IS DISTINCT FROM r.user_id;
 RETURN result;
END $$;

CREATE FUNCTION public.read_crew_urgency_observations(actor uuid,report_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE role_name text; items jsonb;
BEGIN
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor;
 IF role_name IS NULL OR role_name NOT IN ('officer','admin','field_crew') THEN RAISE EXCEPTION 'Staff access required.' USING ERRCODE='42501'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.recorded_at DESC,q.operation_id),'[]'::jsonb) INTO items FROM (
  SELECT o.operation_id,o.report_id,o.task_id,o.observed_result,o.conditions,o.evidence_snapshot,o.recorded_at,
    CASE WHEN v.observation_id IS NOT NULL THEN jsonb_build_object('reason',v.reason,'reviewed_at',v.reviewed_at) END AS review
  FROM public.crew_urgency_observations o LEFT JOIN public.crew_urgency_reviews v ON v.observation_id=o.operation_id
  WHERE o.report_id=read_crew_urgency_observations.report_id AND (role_name IN ('officer','admin') OR o.actor_id=actor)
  ORDER BY o.recorded_at DESC,o.operation_id LIMIT 50
 ) q;
 RETURN jsonb_build_object('observations',items,'limit',50);
END $$;

CREATE FUNCTION public.review_crew_urgency_observation(actor uuid,report_id uuid,observation_id text,reason text,operation_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE role_name text; o public.crew_urgency_observations; prior public.crew_urgency_reviews; normalized text:=btrim(reason);
BEGIN
 -- Serialize reviews without granting UPDATE on immutable observations.
 PERFORM pg_advisory_xact_lock(hashtextextended(observation_id,72631011));
 SELECT * INTO o FROM public.crew_urgency_observations WHERE crew_urgency_observations.operation_id=observation_id;
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor FOR SHARE;
 IF role_name IS NULL OR role_name NOT IN ('officer','admin') OR o.actor_id=actor THEN RAISE EXCEPTION 'Officer review required; no self-review.' USING ERRCODE='42501'; END IF;
 IF o.operation_id IS NULL OR o.report_id IS DISTINCT FROM report_id THEN RAISE EXCEPTION 'Observation not found.' USING ERRCODE='P0002'; END IF;
 IF EXISTS(SELECT 1 FROM public.reports WHERE id=report_id AND user_id=actor) THEN RAISE EXCEPTION 'No review of your own report.' USING ERRCODE='42501'; END IF;
 IF operation_id IS NULL OR normalized IS NULL OR char_length(normalized) NOT BETWEEN 3 AND 1500 THEN RAISE EXCEPTION 'Provide a review reason (3-1500 characters) and operation ID.' USING ERRCODE='22023'; END IF;
 SELECT * INTO prior FROM public.crew_urgency_reviews v WHERE v.observation_id=review_crew_urgency_observation.observation_id;
 IF prior.observation_id IS NOT NULL THEN
  IF prior.operation_id IS DISTINCT FROM operation_id OR prior.actor_id IS DISTINCT FROM actor OR prior.reason IS DISTINCT FROM normalized THEN
   RAISE EXCEPTION 'Observation already reviewed; refresh the saved review.' USING ERRCODE='23505';
  END IF;
  RETURN to_jsonb(prior)-'actor_id';
 END IF;
 INSERT INTO public.crew_urgency_reviews(observation_id,operation_id,actor_id,reason) VALUES(observation_id,operation_id,actor,normalized) RETURNING * INTO prior;
 RETURN to_jsonb(prior)-'actor_id';
END $$;
REVOKE ALL ON FUNCTION public.authorize_citizen_trust_review(uuid,uuid),public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint),
 workflow_private.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint),public.read_crew_urgency_observations(uuid,uuid),
 public.review_crew_urgency_observation(uuid,uuid,text,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.authorize_citizen_trust_review(uuid,uuid),public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint),
 workflow_private.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint),public.read_crew_urgency_observations(uuid,uuid),
 public.review_crew_urgency_observation(uuid,uuid,text,text,uuid) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
