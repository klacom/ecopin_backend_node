-- Rollback: 20261012093000_recover_expired_planning_jobs_in_watchdog.sql
-- Restores previous expire_unpublished_dispatch_claims without planning jobs recovery.

CREATE OR REPLACE FUNCTION public.expire_unpublished_dispatch_claims()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare task public.cleanup_tasks; expired integer:=0; escalated integer:=0;
begin
  for task in select * from public.cleanup_tasks where route_status='needs_replan'
    and routing_deadline_at<=now()+interval '15 minutes' order by id for update skip locked loop
    if task.routing_deadline_at<=now() and task.assigned_at is null and coalesce(cardinality(task.assigned_crew_ids),0)=0 and task.status::text in ('created','pending') then
      update public.cleanup_tasks set route_status='expired',status='cancelled',failure_class='transient',
        failure_reason='Unpublished route planning expired',completion_result='routing_expired' where id=task.id;
      expired:=expired+1;
    elsif task.routing_escalated_at is null then
      update public.cleanup_tasks set routing_escalated_at=now() where id=task.id;
      insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
        values('ROUTING_ESCALATION','TASK',task.id::text,'system',jsonb_build_object('routing_deadline_at',task.routing_deadline_at,'assigned_at',task.assigned_at));
      escalated:=escalated+1;
    end if;
  end loop;
  return jsonb_build_object('expiredCount',expired,'escalatedCount',escalated);
end; $function$;

revoke all on function public.expire_unpublished_dispatch_claims() from public, anon, authenticated;
grant execute on function public.expire_unpublished_dispatch_claims() to postgres, service_role;
