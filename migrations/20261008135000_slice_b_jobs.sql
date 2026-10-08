begin;

create function public.enqueue_plan_generation(actor uuid, plan_mode text, settings jsonb, request_key text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job public.plan_generation_jobs;
begin
  perform workflow_private.require_desk_actor(actor);
  if plan_mode not in ('standard','sweeper','mixed') or jsonb_typeof(settings) is distinct from 'object'
     or length(coalesce(request_key,''))>120 then raise exception 'Invalid plan generation request'; end if;
  if request_key is null then
    insert into public.plan_generation_jobs(requested_by,mode,settings_snapshot)
      values(actor,plan_mode,settings) returning * into job;
  else
    insert into public.plan_generation_jobs(requested_by,mode,settings_snapshot,idempotency_key)
      values(actor,plan_mode,settings,request_key)
      on conflict(requested_by,idempotency_key) where idempotency_key is not null
      do update set idempotency_key=excluded.idempotency_key returning * into job;
    if job.mode<>plan_mode or job.settings_snapshot<>settings then
      raise exception 'Idempotency key already used for a different request';
    end if;
  end if;
  return jsonb_build_object('jobId',job.id,'status',job.status,'planId',job.plan_id);
end; $$;

create function public.claim_plan_generation(worker_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job public.plan_generation_jobs;
begin
  if worker_id is null then raise exception 'Worker token required'; end if;
  update public.plan_generation_jobs set status='failed',finished_at=now(),error_code='worker_lease_expired'
    where status='running' and lease_until<now();
  update public.plan_generation_jobs set status='running',started_at=now(),
    lease_until=now()+interval '3 minutes',worker_token=worker_id
    where id=(select id from public.plan_generation_jobs where status='queued'
      order by requested_at,id for update skip locked limit 1)
    returning * into job;
  if not found then return null; end if;
  return to_jsonb(job);
end; $$;

create function public.finish_plan_generation(job_id uuid, worker_id uuid, result_plan_id uuid,
  failure_code text default null, diagnostics jsonb default '{}'::jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job public.plan_generation_jobs;
begin
  select * into job from public.plan_generation_jobs where id=job_id for update;
  if not found or job.status<>'running' or job.worker_token is distinct from worker_id
    or job.lease_until<now() then raise exception 'Planning job lease expired'; end if;
  if (result_plan_id is null)=(failure_code is null) then raise exception 'Exactly one plan or failure is required'; end if;
  if result_plan_id is not null then
    perform id from public.dispatch_plans where id=result_plan_id and generation_job_id=job_id
      and status='draft' for update;
    if not found then raise exception 'Planning draft is missing or not owned by job'; end if;
  end if;
  update public.plan_generation_jobs set status=case when result_plan_id is null then 'failed' else 'completed' end,
    plan_id=result_plan_id,error_code=left(failure_code,200),finished_at=now(),lease_until=null,
    solver_diagnostics=coalesce(diagnostics,'{}'::jsonb)
    where id=job_id returning * into job;
  return to_jsonb(job);
end; $$;

revoke all on function public.enqueue_plan_generation(uuid,text,jsonb,text),
  public.claim_plan_generation(uuid),public.finish_plan_generation(uuid,uuid,uuid,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.enqueue_plan_generation(uuid,text,jsonb,text),
  public.claim_plan_generation(uuid),public.finish_plan_generation(uuid,uuid,uuid,text,jsonb)
  to service_role;

create function workflow_private.require_completed_plan_job()
returns trigger language plpgsql set search_path='' as $$
declare generation_id uuid;
begin
  if new.source_plan_id is null then return new; end if;
  select generation_job_id into generation_id from public.dispatch_plans where id=new.source_plan_id;
  if generation_id is not null and not exists(select 1 from public.plan_generation_jobs
    where id=generation_id and status='completed' and plan_id=new.source_plan_id) then
    raise exception 'Planning job has not completed';
  end if;
  return new;
end; $$;
create trigger require_completed_plan_job before insert on public.cleanup_tasks
  for each row execute function workflow_private.require_completed_plan_job();

commit;
