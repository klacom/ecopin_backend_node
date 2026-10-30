-- reports_view has no latitude/longitude columns; derive them from reports.location so case records stop failing with 503.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE OR REPLACE FUNCTION public.read_incident_case_record(actor uuid,incident_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE source jsonb; activity jsonb; events jsonb; proof jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')) THEN
  RAISE EXCEPTION 'Desk case record access required' USING ERRCODE='42501';
 END IF;
 SELECT to_jsonb(r)||jsonb_build_object('latitude',extensions.ST_Y(r.location::extensions.geometry),'longitude',extensions.ST_X(r.location::extensions.geometry)) INTO source
 FROM public.reports r WHERE r.id=incident_id;
 IF source IS NULL THEN RETURN NULL; END IF;
 -- The privacy-masked activity projection is the source, never raw audit snapshots/metadata.
 -- Owner identity is excluded from portable case copies even when the account disclosed its name.
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',a.id,'actor_id',CASE WHEN a.user_id::text=source->>'user_id' THEN NULL ELSE a.user_id END,'action_type',a.action_type,
  'action_details',a.action_details,'occurred_at',a.created_at) ORDER BY a.created_at,a.id),'[]'::jsonb) INTO activity
 FROM (SELECT * FROM public.report_activity_view a WHERE a.report_id=incident_id ORDER BY a.created_at,a.id LIMIT 10001) a;
 WITH task_ids AS (
  SELECT (source->>'cleanup_task_id')::uuid AS id
  UNION SELECT e.task_id FROM public.operational_events e WHERE e.report_id=incident_id AND e.task_id IS NOT NULL
 ), relevant AS (
  SELECT e.* FROM public.operational_events e WHERE e.report_id=incident_id OR
   (e.report_id IS NULL AND e.task_id IN (SELECT id FROM task_ids)) ORDER BY e.id LIMIT 10001
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id::text,'event_type',e.event_type,'task_id',e.task_id,
  'scope',CASE WHEN e.report_id IS NULL THEN 'task_context' ELSE 'incident' END,
  'actor_id',CASE WHEN e.actor_id::text=source->>'user_id' THEN NULL ELSE e.actor_id END,'assignment_generation',e.assignment_generation,'occurred_at',e.occurred_at,'recorded_at',e.recorded_at,'time_basis',e.time_basis,
  'details',jsonb_strip_nulls(jsonb_build_object('slot',e.details->'slot','disposition',e.details->'disposition','assigned',e.details->'assigned')))
  ORDER BY e.id),'[]'::jsonb) INTO events FROM relevant e;
 IF jsonb_array_length(activity)>10000 OR jsonb_array_length(events)>10000 THEN
  RAISE EXCEPTION 'Case history is too large for one printable record; no partial record was produced' USING ERRCODE='54000';
 END IF;
 proof:=public.read_cleanup_proof(incident_id);
 RETURN jsonb_build_object('version','case-record-v1','snapshot_at',statement_timestamp(),
  'report',jsonb_build_object('id',source->'id','title',source->'title','description',source->'description',
   'created_at',source->'created_at','status',source->'status','stage',source->'stage','validation_status',source->'validation_status',
   'issue_type',source->'issue_type','citizen_priority',source->'citizen_priority','latitude',source->'latitude','longitude',source->'longitude',
   'street_address',source->'street_address','barangay',source->'barangay','city',source->'city',
   'barangay_resolution_status',source->'barangay_resolution_status','location_precision',source->'location_precision',
   'citizen_landmark',source->'citizen_landmark','on_private_property',source->'on_private_property',
   'property_owner_consent_status',source->'property_owner_consent_status','cleanup_task_id',source->'cleanup_task_id'),
  'activity',activity,'events',events,
  'proof',CASE WHEN proof IS NULL THEN NULL ELSE jsonb_build_object('id',proof->'id','public_notes',proof->'public_notes',
   'completed_at',proof->'completed_at','verified_at',proof->'verified_at') END);
END; $$;

REVOKE ALL ON FUNCTION public.read_incident_case_record(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_incident_case_record(uuid,uuid) TO service_role;
COMMIT;
