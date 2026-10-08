\set ON_ERROR_STOP on
begin;
create function pg_temp.assert_true(result boolean,message text) returns void language plpgsql as $$
begin if result is distinct from true then raise exception 'Assertion failed: %',message; end if; end; $$;

select pg_temp.assert_true(workflow_private.severity_tier(0)='low','0 is low');
select pg_temp.assert_true(workflow_private.severity_tier(33)='low','33 is low');
select pg_temp.assert_true(workflow_private.severity_tier(34)='medium','34 is medium');
select pg_temp.assert_true(workflow_private.severity_tier(66)='medium','66 is medium');
select pg_temp.assert_true(workflow_private.severity_tier(67)='high','67 is high');
select pg_temp.assert_true(workflow_private.severity_tier(100)='high','100 is high');
select pg_temp.assert_true(workflow_private.severity_tier(null)='unknown','unknown is explicit');
do $$ begin
  begin
    perform public.activate_report_lifecycle(48);
    raise exception 'Invalid activation was accepted';
  exception when raise_exception then
    if sqlerrm='Invalid activation was accepted' then raise; end if;
  end;
end; $$;
select pg_temp.assert_true(not exists(select 1 from workflow_private.lifecycle_deployment),'invalid activation leaves no marker');

insert into public.reports(id,status,created_at,severity_score) values
 ('00000000-0000-0000-0000-000000000001','unresolved',now()-interval '100 days',67),
 ('00000000-0000-0000-0000-000000000002','closed',now()-interval '100 days',33);
create temporary table before_reset as select * from public.reports;
-- Twelve hours is a test fixture, not an approved production default.
set local role service_role;
select public.activate_report_lifecycle(12);
reset role;
select pg_temp.assert_true((select r.created_at=b.created_at from public.reports r join before_reset b using(id) where r.status='unresolved'),'created_at preserved');
select pg_temp.assert_true((select r.deadline_at=r.sla_started_at+interval '48 hours' and r.lifecycle_state='fresh' and r.breached_at is null and not r.is_outlier from public.reports r where r.status='unresolved'),'no historical queue flood');
select pg_temp.assert_true((select a.original_deadline_at=b.deadline_at from workflow_private.historical_sla_reset a join before_reset b on b.id=a.report_id),'original deadline archived');
select pg_temp.assert_true((select count(*)=1 from workflow_private.historical_sla_reset),'only unresolved reports reset');
select pg_temp.assert_true((select lifecycle_state='closed' and breached_at is null from public.reports where status='closed'),'closed historical facts not invented');
create temporary table first_baseline as select sla_started_at from public.reports where status='unresolved';
select public.activate_report_lifecycle(6);
select pg_temp.assert_true((select r.sla_started_at=b.sla_started_at from public.reports r cross join first_baseline b where r.status='unresolved'),'reactivation does not reset clock');
select pg_temp.assert_true((select (parameter_value->>'hours')::numeric=12 from public.sweeper_configuration where parameter_name='high_severity_maturation_hours'),'reactivation does not silently change policy');

insert into public.reports(id,severity_score) values('00000000-0000-0000-0000-000000000003',67);
update public.reports set severity_score=5,deadline_at=now()+interval '100 days',sla_started_at=now()+interval '10 days' where id='00000000-0000-0000-0000-000000000003';
select pg_temp.assert_true((select deadline_at=sla_started_at+interval '48 hours' and sla_started_at<=clock_timestamp() from public.reports where id='00000000-0000-0000-0000-000000000003'),'severity edit/client timestamps cannot restart SLA');
insert into public.reports(id,severity_score) values
 ('00000000-0000-0000-0000-000000000004',67),
 ('00000000-0000-0000-0000-000000000005',66);

-- Inject a due fixture while disabling only the derivation trigger in this isolated database.
alter table public.reports disable trigger zz_apply_report_lifecycle;
update public.reports set sla_started_at=now()-interval '13 hours',deadline_at=now()+interval '35 hours'
  where id in ('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005');
update public.reports set sla_started_at=now()-interval '49 hours',deadline_at=now()-interval '1 hour',cleanup_task_id=gen_random_uuid()
  where id='00000000-0000-0000-0000-000000000003';
alter table public.reports enable trigger zz_apply_report_lifecycle;
set local role service_role;
select public.advance_report_lifecycle();
reset role;
select pg_temp.assert_true((select lifecycle_state='maturing' and matured_at is not null from public.reports where id='00000000-0000-0000-0000-000000000004'),'high severity matures sooner');
select pg_temp.assert_true((select lifecycle_state='fresh' and matured_at is null from public.reports where id='00000000-0000-0000-0000-000000000005'),'medium severity retains normal window');
select pg_temp.assert_true((select lifecycle_state='dispatched' and matured_at is not null and breached_at=deadline_at from public.reports where id='00000000-0000-0000-0000-000000000003'),'dispatched report retains SLA history');
create temporary table history as select matured_at,breached_at from public.reports where id='00000000-0000-0000-0000-000000000003';
update public.reports set cleanup_task_id=null,breached_at=null,matured_at=null where id='00000000-0000-0000-0000-000000000003';
select pg_temp.assert_true((select lifecycle_state='sla_breached' and r.breached_at=h.breached_at and r.matured_at=h.matured_at from public.reports r cross join history h where id='00000000-0000-0000-0000-000000000003'),'release derives reverse state and cannot erase stamps');
update public.reports set status='closed' where id='00000000-0000-0000-0000-000000000003';
select pg_temp.assert_true((select lifecycle_state='closed' and breached_at is not null and not is_outlier from public.reports where id='00000000-0000-0000-0000-000000000003'),'closure preserves breach history');

-- No-op run still has a durable success event, without duplicate breach events.
select public.advance_report_lifecycle();
select pg_temp.assert_true((select count(*)=1 from public.sweeper_audit_log where event_type='SLA_BREACH_DETECTED'),'breach event emitted once');
select pg_temp.assert_true((select count(*)>=2 from public.sweeper_audit_log where event_type='LIFECYCLE_RUN_COMPLETED'),'no-op run observable');
-- An audit failure must roll back the report change in the same transaction.
create function pg_temp.reject_audit() returns trigger language plpgsql as $$
begin raise exception 'fixture audit failure'; end; $$;
create trigger fixture_reject_audit before insert on public.sweeper_audit_log
  for each row execute function pg_temp.reject_audit();
do $$ begin
  begin
    update public.reports set cluster_id=gen_random_uuid() where id='00000000-0000-0000-0000-000000000001';
    raise exception 'Audit failure did not abort report update';
  exception when raise_exception then
    if sqlerrm <> 'fixture audit failure' then raise; end if;
  end;
end; $$;
drop trigger fixture_reject_audit on public.sweeper_audit_log;
select pg_temp.assert_true((select cluster_id is null and lifecycle_state='fresh' from public.reports where id='00000000-0000-0000-0000-000000000001'),'audit and report mutation are atomic');
select pg_temp.assert_true(not has_function_privilege('anon','public.advance_report_lifecycle()','EXECUTE'),'anon cannot advance');
select pg_temp.assert_true(not has_function_privilege('authenticated','public.activate_report_lifecycle(numeric,numeric)','EXECUTE'),'client cannot reset clock');

do $$ begin
  begin
    update public.sweeper_configuration set parameter_value='{"hours":10}' where parameter_name='sla_threshold';
    raise exception 'Invalid policy was accepted';
  exception when raise_exception then
    if sqlerrm='Invalid policy was accepted' then raise; end if;
  end;
end; $$;
select pg_temp.assert_true((select (parameter_value->>'hours')::integer=48 from public.sweeper_configuration where parameter_name='sla_threshold'),'invalid configuration rolled back');

-- Exact boundaries and the matrix of precedence do not depend on wall-clock timing.
select pg_temp.assert_true(workflow_private.derive_report_lifecycle('unresolved',null,null,'2026-10-08 00:00Z','2026-10-10 00:00Z',12,'2026-10-08 12:00Z')='maturing','high maturation boundary');
select pg_temp.assert_true(workflow_private.derive_report_lifecycle('unresolved',null,null,'2026-10-08 00:00Z','2026-10-10 00:00Z',24,'2026-10-08 12:00Z')='fresh','normal maturation later');
select pg_temp.assert_true(workflow_private.derive_report_lifecycle('unresolved',gen_random_uuid(),null,'2026-10-08 00:00Z','2026-10-10 00:00Z',24,'2026-10-10 00:00Z')='clustered','cluster precedence');
select pg_temp.assert_true(workflow_private.derive_report_lifecycle('unresolved',null,null,'2026-10-08 00:00Z','2026-10-10 00:00Z',24,'2026-10-10 00:00Z')='sla_breached','deadline boundary');
rollback;
