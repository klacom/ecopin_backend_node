SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='30s';
CREATE OR REPLACE FUNCTION public.apply_fc_operation(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
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
$function$
;
DROP POLICY sync_conflicts_service_role_all ON public.sync_conflicts;
ALTER TABLE public.sync_conflicts DISABLE ROW LEVEL SECURITY;

