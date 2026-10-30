-- PDT-15: status transitions share the operational journal; presence proves server contact only.
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.operational_events DROP CONSTRAINT operational_events_event_type_check;
ALTER TABLE public.operational_events ADD CONSTRAINT operational_events_event_type_check
 CHECK(event_type IN ('assignment','acknowledgement','arrival','evidence_submission','completion','verification','task_transition'));
CREATE INDEX operational_events_live_task ON public.operational_events(id DESC) WHERE task_id IS NOT NULL;
CREATE FUNCTION operational_private.capture_task_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE previous text:=CASE WHEN TG_OP='UPDATE' THEN OLD.status::text END;
BEGIN
 IF TG_OP='INSERT' OR NEW.status::text IS DISTINCT FROM previous THEN
  PERFORM operational_private.emit('task_transition',NEW.id,NULL,
   nullif(current_setting('ecopin.operational_actor',true),'')::uuid,NEW.assignment_generation,
   clock_timestamp(),'server',gen_random_uuid()::text,
   jsonb_build_object('from_status',previous,'to_status',NEW.status::text));
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER operational_task_transition AFTER INSERT OR UPDATE OF status ON public.cleanup_tasks
 FOR EACH ROW EXECUTE FUNCTION operational_private.capture_task_transition();
REVOKE ALL ON FUNCTION operational_private.capture_task_transition() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION operational_private.capture_task_transition() TO service_role;
CREATE TABLE operational_private.crew_presence (
 crew_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 last_seen_at timestamptz NOT NULL CHECK(isfinite(last_seen_at) AND last_seen_at>=timestamptz '2020-01-01 00:00Z' AND last_seen_at<timestamptz '10000-01-01 00:00Z')
);
ALTER TABLE operational_private.crew_presence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational_private.crew_presence FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT,UPDATE ON operational_private.crew_presence TO service_role;
CREATE FUNCTION public.touch_crew_presence(actor uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE seen timestamptz;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text='field_crew'
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active field crew required' USING ERRCODE='42501';
 END IF;
 INSERT INTO operational_private.crew_presence(crew_id,last_seen_at) VALUES(actor,statement_timestamp())
 ON CONFLICT(crew_id) DO UPDATE SET last_seen_at=excluded.last_seen_at
  WHERE crew_presence.last_seen_at<excluded.last_seen_at-interval '20 seconds' RETURNING last_seen_at INTO seen;
 IF seen IS NULL THEN SELECT last_seen_at INTO seen FROM operational_private.crew_presence WHERE crew_id=actor; END IF;
 RETURN jsonb_build_object('seen_at',seen);
END; $$;
CREATE FUNCTION public.read_live_operations(actor uuid,before_id bigint DEFAULT NULL,page_limit integer DEFAULT 20) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active staff access required' USING ERRCODE='42501';
 END IF;
 IF page_limit IS NULL OR page_limit<1 OR page_limit>100 OR before_id<1 THEN RAISE EXCEPTION 'Invalid feed page' USING ERRCODE='22023'; END IF;
 IF (SELECT count(*) FROM public.field_crews)>500 THEN RAISE EXCEPTION 'Crew roster exceeds feed capacity; no partial roster returned' USING ERRCODE='54000'; END IF;
 WITH page AS (
  SELECT * FROM public.operational_events e WHERE e.task_id IS NOT NULL AND (before_id IS NULL OR e.id<before_id)
  ORDER BY e.id DESC LIMIT page_limit+1
 ), visible AS (SELECT * FROM page ORDER BY id DESC LIMIT page_limit), people AS MATERIALIZED (
  SELECT p.id,h.last_seen_at FROM public.profiles p LEFT JOIN operational_private.crew_presence h ON h.crew_id=p.id
  WHERE p.role::text='field_crew' AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())
 ), membership AS (
  SELECT DISTINCT f.id AS crew_id,p.id AS member_id,p.last_seen_at FROM public.field_crews f
  CROSS JOIN LATERAL unnest(coalesce(f.member_profile_ids,'{}'::uuid[])||ARRAY[f.team_lead_profile_id]) u(id)
  JOIN people p ON p.id=u.id
 ), groups AS (
  SELECT f.id AS crew_id,f.name FROM public.field_crews f
  UNION ALL SELECT NULL,'Other field crew' WHERE EXISTS(SELECT 1 FROM people p WHERE NOT EXISTS(SELECT 1 FROM membership m WHERE m.member_id=p.id))
 ), members AS (
  SELECT * FROM membership UNION ALL SELECT NULL,p.id,p.last_seen_at FROM people p WHERE NOT EXISTS(SELECT 1 FROM membership m WHERE m.member_id=p.id)
 ), roster AS (
  SELECT g.crew_id,g.name,count(m.member_id) AS member_count,
   count(m.member_id) FILTER(WHERE m.last_seen_at>=statement_timestamp()-interval '90 seconds') AS recent_members,
   count(m.member_id) FILTER(WHERE m.last_seen_at<statement_timestamp()-interval '90 seconds') AS quiet_members,
   count(m.member_id) FILTER(WHERE m.last_seen_at IS NULL) AS unknown_members,max(m.last_seen_at) AS last_seen_at
  FROM groups g LEFT JOIN members m ON m.crew_id IS NOT DISTINCT FROM g.crew_id GROUP BY g.crew_id,g.name
 ) SELECT jsonb_build_object('version','live-operations-v1','generated_at',statement_timestamp(),'presence_window_seconds',90,
  'latest_event_id',(SELECT max(id)::text FROM public.operational_events WHERE task_id IS NOT NULL),
  'events',coalesce((SELECT jsonb_agg(jsonb_build_object('event_id',e.id::text,'event_type',e.event_type,'task_id',e.task_id,
   'occurred_at',e.occurred_at,'recorded_at',e.recorded_at,'time_basis',e.time_basis,
   'details',jsonb_strip_nulls(jsonb_build_object('from_status',e.details->'from_status','to_status',e.details->'to_status','assigned',e.details->'assigned','slot',e.details->'slot','disposition',e.details->'disposition')))
   ORDER BY e.id DESC) FROM visible e),'[]'::jsonb),
  'has_more',(SELECT count(*)>page_limit FROM page),'next_cursor',CASE WHEN (SELECT count(*)>page_limit FROM page) THEN (SELECT min(id)::text FROM visible) END,
  'crew_count',(SELECT count(*) FROM people),'recent_members',(SELECT count(*) FROM people WHERE last_seen_at>=statement_timestamp()-interval '90 seconds'),
  'quiet_members',(SELECT count(*) FROM people WHERE last_seen_at<statement_timestamp()-interval '90 seconds'),'unknown_members',(SELECT count(*) FROM people WHERE last_seen_at IS NULL),
  'crews',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY name,crew_id) FROM roster r),'[]'::jsonb)) INTO result;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.touch_crew_presence(uuid),public.read_live_operations(uuid,bigint,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.touch_crew_presence(uuid),public.read_live_operations(uuid,bigint,integer) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
