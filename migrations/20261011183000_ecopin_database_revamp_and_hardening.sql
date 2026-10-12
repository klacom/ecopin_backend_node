-- EcoPin Migration: 20261011183000_ecopin_database_revamp_and_hardening.sql
-- Comprehensive database optimization, security hardening, and schema alignment.

-- 1. Compatibility view for response_log over audit_logs
CREATE OR REPLACE VIEW public.response_log WITH (security_invoker = true) AS
SELECT id, report_id, user_id, action_type, action_details, created_at
FROM public.audit_logs;

ALTER VIEW public.response_log OWNER TO postgres;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.response_log TO authenticated, service_role;

-- 2. Secure reports_view with security_invoker = true
ALTER VIEW public.reports_view SET (security_invoker = true);

-- 3. Fix PostGIS search_path on count_recent_nearby_reports RPC
CREATE OR REPLACE FUNCTION public.count_recent_nearby_reports(
    p_lon double precision, 
    p_lat double precision, 
    p_radius_meters double precision, 
    p_days integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $function$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT count(*) INTO v_count
    FROM public.reports
    WHERE extensions.ST_DWithin(
        location::extensions.geography,
        extensions.ST_SetSRID(extensions.ST_MakePoint(p_lon, p_lat), 4326)::extensions.geography,
        p_radius_meters
    )
    AND created_at >= NOW() - (p_days || ' days')::INTERVAL;
    RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.count_recent_nearby_reports(double precision, double precision, double precision, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.count_recent_nearby_reports(double precision, double precision, double precision, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.count_recent_nearby_reports(double precision, double precision, double precision, integer) TO authenticated, service_role;

-- 4. Payload idempotency validation in apply_fc_operation
CREATE OR REPLACE FUNCTION public.apply_fc_operation(
  actor uuid, 
  operation_id text, 
  operation_type text, 
  entity_id uuid, 
  entity_type text, 
  payload jsonb, 
  base_version bigint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, extensions
AS $function$
declare 
  prior public.fc_operation_log; 
  report public.reports; 
  task public.cleanup_tasks; 
  patched public.reports;
  actor_role text; 
  claim uuid; 
  result jsonb; 
  note public.response_log; 
  allowed text[]; 
  key text; 
  identical boolean;
begin
  if operation_id is null or length(operation_id) not between 1 and 200 or jsonb_typeof(payload) is distinct from 'object'
    or base_version is null or base_version < 0 then 
    raise exception 'Invalid sync operation' using errcode = '22023'; 
  end if;

  select role::text into actor_role from public.profiles where id = actor;
  if actor_role is null or actor_role not in ('admin', 'officer', 'field_crew') then 
    raise exception 'Field operations access required' using errcode = '42501'; 
  end if;

  perform pg_advisory_xact_lock(hashtextextended(operation_id, 72631009));

  select * into prior from public.fc_operation_log l where l.operation_id = apply_fc_operation.operation_id;
  if found then
    if prior.user_id <> actor or prior.entity_id <> entity_id::text or prior.operation_type::text <> operation_type then
      raise exception 'Operation ID belongs to another request' using errcode = '42501';
    end if;
    if (prior.result->'payload') is not null and (prior.result->'payload') is distinct from payload then
      raise exception 'Operation ID reused with different payload' using errcode = '22023';
    end if;
    if (prior.result->>'payload_hash') is not null and prior.result->>'payload_hash' <> md5(payload::text) then
      raise exception 'Operation ID reused with different payload' using errcode = '22023';
    end if;
    return prior.result || jsonb_build_object('operation_id', operation_id, 'replayed', true);
  end if;

  if operation_type = 'fc.task.mark_complete' and entity_type = 'task' then
    result := public.submit_task_outcome(
      entity_id, actor, coalesce(payload->>'outcome', 'completed'), coalesce(payload->>'notes', ''),
      payload->>'failure_class', base_version, operation_id
    );
  elsif entity_type = 'report' and operation_type in (
    'fc.report.update_status', 'fc.report.update_lifecycle_stage', 'fc.report.update_validation', 
    'fc.report.update_details', 'fc.note.add'
  ) then
    select cleanup_task_id into claim from public.reports where id = entity_id;
    if claim is not null then 
      select * into task from public.cleanup_tasks where id = claim for update; 
    end if;

    select * into report from public.reports where id = entity_id for update;
    if not found then 
      raise exception 'Report not found' using errcode = 'P0002'; 
    end if;

    if actor_role = 'field_crew' and (
      report.cleanup_task_id is distinct from claim or claim is null
      or task.status::text in ('completed', 'cancelled') or not workflow_private.can_execute_task(actor, task)
    ) then
      raise exception 'Report is not assigned to this crew' using errcode = '42501';
    end if;

    if operation_type = 'fc.note.add' then
      if nullif(btrim(coalesce(payload->>'action', payload->>'action_details')), '') is null then 
        raise exception 'Note text required'; 
      end if;
      insert into public.response_log(report_id, user_id, action_type, action_details)
        values(entity_id, actor, 'manual_note', coalesce(payload->>'action', payload->>'action_details')) 
        returning * into note;
      result := jsonb_build_object('status', 'success', 'server_record', to_jsonb(note));
    else
      allowed := case operation_type 
        when 'fc.report.update_status' then array['status']
        when 'fc.report.update_lifecycle_stage' then array['stage']
        when 'fc.report.update_validation' then array['validation_status']
        else array['notes', 'stage'] 
      end;

      for key in select jsonb_object_keys(payload) loop
        if not (key = any(allowed)) then 
          raise exception 'Field is server-owned or unsupported: %', key using errcode = '42501'; 
        end if;
      end loop;

      if payload ? 'status' and payload->>'status' not in ('in_progress', 'resolved') then 
        raise exception 'Use a classified task outcome for closure or failure'; 
      end if;

      if report.status::text in ('resolved', 'completed', 'closed', 'rejected') then
        result := jsonb_build_object('status', 'conflict', 'server_record', to_jsonb(report), 'error_message', 'Report is terminal');
      else
        select bool_and(to_jsonb(report)->k is not distinct from payload->k) into identical 
        from jsonb_object_keys(payload) k;

        if coalesce(identical, false) then 
          result := jsonb_build_object('status', 'success', 'server_record', to_jsonb(report));
        elsif base_version <> report.fc_version then
          result := jsonb_build_object(
            'status', 'conflict', 
            'server_record', to_jsonb(report), 
            'error_message', 'Report version changed',
            'conflict_detail', jsonb_build_object(
              'rule', 'first_accepted_wins', 
              'server_version', report.fc_version, 
              'client_base_version', base_version
            )
          );
        else
          patched := jsonb_populate_record(report, payload);
          update public.reports set 
            status = patched.status, 
            stage = patched.stage, 
            notes = patched.notes, 
            validation_status = patched.validation_status,
            lgu_resolved_at = case when patched.status::text = 'resolved' then now() else lgu_resolved_at end,
            updated_at = now()
          where id = entity_id returning * into report;
          result := jsonb_build_object('status', 'success', 'server_record', to_jsonb(report));
        end if;
      end if;
    end if;
  else 
    raise exception 'Unsupported sync operation' using errcode = '22023'; 
  end if;

  result := result || jsonb_build_object('operation_id', operation_id, 'payload', payload, 'payload_hash', md5(payload::text));

  if result->>'status' = 'conflict' then
    insert into public.fc_conflict_audit(
      operation_id, user_id, operation_type, entity_id, entity_type, outcome, 
      client_base_version, server_version, payload, server_state_snapshot, reason
    )
    values(
      operation_id, actor, operation_type::public.sync_operation_type, entity_id::text, entity_type::public.sync_entity_type, 
      'rejected', base_version, (result->'server_record'->>'fc_version')::bigint, payload, result->'server_record', result->>'error_message'
    );
  end if;

  insert into public.fc_operation_log(operation_id, user_id, operation_type, entity_id, entity_type, status, result)
    values(
      operation_id, actor, operation_type::public.sync_operation_type, entity_id::text, 
      entity_type::public.sync_entity_type, result->>'status', result
    );

  return result;
end; 
$function$;

-- 5. Restrict notifications UPDATE privileges to is_read
REVOKE UPDATE ON public.notifications FROM PUBLIC, authenticated;
GRANT UPDATE (is_read) ON public.notifications TO authenticated;

-- 6. Storage RLS policies on media buckets
ALTER POLICY "Authenticated users can upload Report Evidence" ON storage.objects
WITH CHECK (
  bucket_id = 'Report Evidence'
  AND (
    (storage.foldername(name))[1] = (select auth.uid())::text
    OR (select public.get_auth_user_role())::text = ANY (ARRAY['officer'::text, 'admin'::text])
  )
);

ALTER POLICY "Authenticated users can upload Cleanup Task Photos" ON storage.objects
WITH CHECK (
  bucket_id = 'Cleanup Task Photos'
  AND (select public.get_auth_user_role())::text = ANY (ARRAY['field_crew'::text, 'officer'::text, 'admin'::text])
);

ALTER POLICY "Authenticated users can upload Report Cleanup" ON storage.objects
WITH CHECK (
  bucket_id = 'Report Cleanup'
  AND (select public.get_auth_user_role())::text = ANY (ARRAY['field_crew'::text, 'officer'::text, 'admin'::text])
);

-- 7. Reports and profiles exposure restrictions
REVOKE SELECT ON public.reports FROM anon;
REVOKE SELECT ON public.reports_view FROM anon;

GRANT SELECT (
  id, title, description, issue_type, location, status, cluster_id, 
  created_at, updated_at, before_photo_url, after_photo_url, stage, 
  satisfaction_rating, lgu_resolved_at, citizen_closed_at, is_overdue, deadline_at
) ON public.reports TO anon;

GRANT SELECT (
  id, title, description, issue_type, location, status, cluster_id, 
  created_at, updated_at, before_photo_url, after_photo_url, stage, 
  satisfaction_rating, lgu_resolved_at, citizen_closed_at, is_overdue, deadline_at
) ON public.reports_view TO anon;

ALTER POLICY "Enable read access for all users" ON public.reports TO anon
USING (
  validation_status = 'approved'::public.report_validation_status
  AND status NOT IN ('rejected'::public.report_status)
);

ALTER POLICY "Reports are viewable by authenticated users" ON public.reports TO authenticated
USING (
  ((select public.get_auth_user_role())::text = ANY (ARRAY['officer'::text, 'admin'::text]))
  OR (user_id = (select auth.uid()))
  OR (validation_status = 'approved'::public.report_validation_status AND status NOT IN ('rejected'::public.report_status))
  OR (cleanup_task_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.cleanup_tasks ct 
    WHERE ct.id = reports.cleanup_task_id 
      AND (select auth.uid()) = ANY(COALESCE(ct.assigned_crew_ids, '{}'::uuid[]))
  ))
);

ALTER POLICY "Public profiles are viewable by authenticated users" ON public.profiles TO authenticated
USING (
  id = (select auth.uid())
  OR ((select public.get_auth_user_role())::text = ANY (ARRAY['officer'::text, 'admin'::text]))
  OR (EXISTS (
    SELECT 1 FROM public.field_crews c
    WHERE (c.team_lead_profile_id = (select auth.uid()) OR (select auth.uid()) = ANY(COALESCE(c.member_profile_ids, '{}'::uuid[])))
      AND (c.team_lead_profile_id = profiles.id OR profiles.id = ANY(COALESCE(c.member_profile_ids, '{}'::uuid[])))
  ))
);

-- 8. Add notifications to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

-- 9. Feed and Composite Performance Indexes
CREATE INDEX IF NOT EXISTS idx_reports_user_feed ON public.reports (user_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread_feed ON public.notifications (user_id, created_at DESC, id DESC) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_dispatch_plans_status_created ON public.dispatch_plans (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cleanup_tasks_crew_status ON public.cleanup_tasks (assigned_field_crew_id, status);
CREATE INDEX IF NOT EXISTS idx_audit_logs_report_created ON public.audit_logs (report_id, created_at DESC);
