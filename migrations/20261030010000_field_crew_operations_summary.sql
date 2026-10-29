-- PDT-32: read-only operational snapshot. Requires PDT-13/14/20 and canonical route/outcome tables.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.get_field_crew_operations_summary(actor uuid,start_day date,end_day date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE first_at timestamptz; until_at timestamptz; result jsonb; size integer;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND role::text IN ('officer','admin')) THEN RAISE EXCEPTION 'Desk operations access required' USING ERRCODE='42501'; END IF;
 IF start_day IS NULL OR end_day IS NULL OR start_day<date '2000-01-01' OR end_day<start_day OR end_day-start_day>365 OR end_day>(statement_timestamp() AT TIME ZONE 'Asia/Manila')::date THEN RAISE EXCEPTION 'Choose 1-366 Manila calendar days ending no later than today' USING ERRCODE='22023'; END IF;
 first_at:=start_day::timestamp AT TIME ZONE 'Asia/Manila';until_at:=(end_day+1)::timestamp AT TIME ZONE 'Asia/Manila';
 WITH events AS MATERIALIZED (
  SELECT * FROM public.operational_events e WHERE e.time_basis='server' AND e.occurred_at>=first_at AND e.occurred_at<until_at AND e.event_type IN ('assignment','completion','verification')
 ), assignments AS (SELECT * FROM events WHERE event_type='assignment' ORDER BY id LIMIT 1001),
 completions AS (
  SELECT 'journal:'||e.id AS ref,e.task_id,e.report_id,e.actor_id,e.occurred_at FROM events e WHERE event_type='completion' AND report_id IS NULL
  UNION ALL SELECT 'task:'||t.id,t.id,NULL::uuid,t.completed_by,t.completed_at FROM public.cleanup_tasks t
   WHERE t.status::text='completed' AND t.completed_at>=first_at AND t.completed_at<until_at
    AND NOT EXISTS(SELECT 1 FROM events e WHERE e.event_type='completion' AND e.report_id IS NULL AND e.task_id=t.id AND e.occurred_at=t.completed_at)
  UNION ALL SELECT 'resolution:'||r.id,r.task_id,r.report_id,r.crew_id,r.resolved_at FROM public.report_resolution_events r WHERE r.resolved_at>=first_at AND r.resolved_at<until_at
 ), waypoint_records AS (
  SELECT DISTINCT ON(w.id) w.id AS waypoint_id,w.crew_route_id,w.sequence_order,w.waypoint_type,c.*,
   cr.crew_id,fc.name AS crew_name
  FROM completions c JOIN public.route_waypoints w ON w.cleanup_task_id=c.task_id AND w.report_id IS NOT DISTINCT FROM c.report_id
  JOIN public.crew_routes cr ON cr.id=w.crew_route_id JOIN public.optimization_runs run ON run.id=cr.optimization_run_id AND run.status::text='approved' AND run.approved_at IS NOT NULL
  LEFT JOIN public.field_crews fc ON fc.id=cr.crew_id ORDER BY w.id,c.occurred_at DESC,c.ref DESC LIMIT 1001
 ), verified AS (SELECT * FROM events WHERE event_type='verification' ORDER BY id LIMIT 1001),
 obstacles AS (
  SELECT * FROM (
   SELECT 'block:'||b.id AS ref,'access_block'::text AS source,b.task_id,b.report_id,b.blocked_by AS actor_id,
    b.blocked_at AS occurred_at,b.blocked_at AS recorded_at,b.failure_class AS kind,b.reason AS notes,
    NULL::text AS disposition,b.cleared_at,b.clearance_notes,b.cleared_by,
    (b.blocked_at>=first_at OR (b.cleared_at>=first_at AND b.cleared_at<until_at)) AS activity_in_period
   FROM public.dispatch_access_blocks b WHERE b.blocked_at<until_at AND (b.blocked_at>=first_at OR (b.cleared_at>=first_at AND b.cleared_at<until_at) OR b.cleared_at IS NULL)
   UNION ALL SELECT 'outcome:'||o.id,'outcome',o.task_id,o.report_id,o.crew_id,o.observed_at,o.submitted_at,o.outcome,o.notes,o.disposition,NULL::timestamptz,NULL::text,NULL::uuid,true
    FROM public.task_report_outcomes o WHERE o.submitted_at>=first_at AND o.submitted_at<until_at AND (o.outcome IN ('unable','skipped') OR o.disposition IN ('contested','verification_required'))
   UNION ALL SELECT 'failure:'||t.id,'task_failure',t.id,NULL::uuid,t.completed_by,t.completed_at,t.completed_at,t.failure_class,t.failure_reason,NULL::text,NULL::timestamptz,NULL::text,NULL::uuid,true
    FROM public.cleanup_tasks t WHERE nullif(btrim(t.failure_reason),'') IS NOT NULL AND t.completed_at>=first_at AND t.completed_at<until_at
  ) b ORDER BY recorded_at,ref LIMIT 1001
 ), task_scope AS (
  SELECT id FROM (
   SELECT t.id FROM public.cleanup_tasks t WHERE (t.created_at>=first_at AND t.created_at<until_at) OR (t.created_at<until_at AND coalesce(t.status::text,'unknown') NOT IN ('completed','cancelled'))
   UNION SELECT task_id FROM events UNION SELECT task_id FROM completions UNION SELECT task_id FROM obstacles
  ) q WHERE id IS NOT NULL ORDER BY id LIMIT 1001
 ), links AS (
  SELECT r.cleanup_task_id AS task_id,r.id AS report_id FROM public.reports r WHERE r.cleanup_task_id IN (SELECT id FROM task_scope)
  UNION SELECT a.task_id,a.report_id FROM public.field_assignment_receipts a WHERE a.task_id IN (SELECT id FROM task_scope)
  UNION SELECT r.task_id,r.report_id FROM public.report_resolution_events r WHERE r.task_id IN (SELECT id FROM task_scope)
  UNION SELECT b.task_id,b.report_id FROM obstacles b WHERE b.report_id IS NOT NULL
 ), owners AS MATERIALIZED (
  SELECT l.task_id,l.report_id,coalesce(h.owner_id,r.user_id) AS owner_id FROM links l LEFT JOIN public.reports r ON r.id=l.report_id LEFT JOIN privacy_private.hidden_report_owners h ON h.report_id=l.report_id
 )
 SELECT jsonb_build_object('version','crew-operations-v1','generated_at',statement_timestamp(),'timezone','Asia/Manila','start_day',start_day,'end_day',end_day,
 'tasks',coalesce((SELECT jsonb_agg(jsonb_build_object('task_id',t.id,'title',t.title,'status',t.status,'created_at',t.created_at,'completed_at',t.completed_at,
  'scheduled_date',t.scheduled_date,'assignment_generation',t.assignment_generation,'current_crew_id',t.assigned_field_crew_id,'current_crew_name',fc.name,
  'current_accounts',coalesce((SELECT jsonb_agg(CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=t.id AND o.owner_id=x) THEN NULL ELSE to_jsonb(x) END) FROM unnest(t.assigned_crew_ids) x),'[]'::jsonb),
  'current_failure_class',t.failure_class,'current_failure_reason',t.failure_reason) ORDER BY t.created_at,t.id)
  FROM public.cleanup_tasks t LEFT JOIN public.field_crews fc ON fc.id=t.assigned_field_crew_id WHERE t.id IN (SELECT id FROM task_scope)),'[]'::jsonb),
 'assignments',coalesce((SELECT jsonb_agg(jsonb_build_object('event_ref','journal:'||e.id,'task_id',e.task_id,'occurred_at',e.occurred_at,'assignment_generation',e.assignment_generation,
  'assigned',e.details->'assigned','actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=e.task_id AND o.owner_id=e.actor_id) THEN NULL ELSE e.actor_id END,
  'receipt_accounts',coalesce((SELECT jsonb_agg(DISTINCT CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=e.task_id AND o.owner_id=a.crew_id) THEN NULL ELSE to_jsonb(a.crew_id) END)
   FROM public.field_assignment_receipts a WHERE a.task_id=e.task_id AND a.assignment_generation=e.assignment_generation),'[]'::jsonb)) ORDER BY e.id) FROM assignments e),'[]'::jsonb),
 'waypoints',coalesce((SELECT jsonb_agg(jsonb_build_object('waypoint_id',w.waypoint_id,'route_id',w.crew_route_id,'sequence',w.sequence_order,'waypoint_type',w.waypoint_type,'crew_id',w.crew_id,'crew_name',w.crew_name,
  'task_id',w.task_id,'report_id',w.report_id,'completion_ref',w.ref,'completed_at',w.occurred_at,
  'actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=w.task_id AND o.owner_id=w.actor_id) THEN NULL ELSE w.actor_id END) ORDER BY w.crew_route_id,w.sequence_order,w.waypoint_id) FROM waypoint_records w),'[]'::jsonb),
 'verified',coalesce((SELECT jsonb_agg(jsonb_build_object('event_ref','journal:'||e.id,'task_id',e.task_id,'report_id',e.report_id,'verified_at',e.occurred_at,'assignment_generation',e.assignment_generation,
  'actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE (o.task_id=e.task_id OR o.report_id=e.report_id) AND o.owner_id=e.actor_id) THEN NULL ELSE e.actor_id END,
  'source_matches',coalesce(p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) AND r.status::text IN ('resolved','completed','closed','waiting_for_feedback'),false)) ORDER BY e.id)
  FROM verified e LEFT JOIN public.cleanup_proof_publications p ON p.id::text=e.details->>'publication_id' AND p.report_id=e.report_id LEFT JOIN public.reports r ON r.id=e.report_id),'[]'::jsonb),
 'obstacles',coalesce((SELECT jsonb_agg(jsonb_build_object('event_ref',b.ref,'source',b.source,'task_id',b.task_id,'report_id',b.report_id,
  'actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE (o.task_id=b.task_id OR o.report_id=b.report_id) AND o.owner_id=b.actor_id) THEN NULL ELSE b.actor_id END,
  'occurred_at',b.occurred_at,'recorded_at',b.recorded_at,'kind',b.kind,'notes',b.notes,'disposition',b.disposition,'cleared_at',b.cleared_at,'cleared_by',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE (o.task_id=b.task_id OR o.report_id=b.report_id) AND o.owner_id=b.cleared_by) THEN NULL ELSE b.cleared_by END,'clearance_notes',b.clearance_notes,'activity_in_period',b.activity_in_period) ORDER BY b.recorded_at,b.ref) FROM obstacles b),'[]'::jsonb)
 ) INTO result;
 SELECT sum(jsonb_array_length(result->k)) INTO size FROM unnest(ARRAY['tasks','assignments','waypoints','verified','obstacles']) k;
 IF size>1000 THEN RAISE EXCEPTION 'Operations summary is too large; narrow the dates. No partial export was produced' USING ERRCODE='54000'; END IF;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.get_field_crew_operations_summary(uuid,date,date) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_field_crew_operations_summary(uuid,date,date) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
