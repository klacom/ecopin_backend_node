-- Run in an isolated database with the photo RPC loaded. No production writes.
create or replace function pg_temp.assert_true(ok boolean, message text)
returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception '%', message; end if;
end $$;
select pg_temp.assert_true(not has_function_privilege('authenticated',
 'public.set_report_photo(uuid,uuid,text,text,text,bigint)','execute'),
 'Client roles cannot call the privileged photo RPC directly');
select pg_temp.assert_true(has_function_privilege('service_role',
 'public.set_report_photo(uuid,uuid,text,text,text,bigint)','execute'),
 'Backend retains RPC access');

insert into public.cleanup_tasks(id,status) values ('00000000-0000-0000-0000-000000000001','pending');
insert into public.reports(id,cleanup_task_id,status,fc_version,after_photo_url)
values ('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','resolved',9,'https://example.test/old');

select pg_temp.assert_true(public.set_report_photo(
 '00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002',
 'after','https://example.test/after','after-hash',9)->>'status'='success',
 'Assigned crew must be able to sync After evidence on a resolved report in an active task');
select pg_temp.assert_true((select status='resolved' and after_photo_url='https://example.test/after'
 from public.reports limit 1),'Evidence upload must preserve resolved status');
select pg_temp.assert_true(public.set_report_photo(
 '00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002',
 'after','https://example.test/stale','hash',8)->>'status'='conflict','Stale version must still conflict');
select pg_temp.assert_true(public.set_report_photo(
 '00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002',
 'after',null,null,9)->>'status'='conflict','Resolved evidence cannot be deleted');
select pg_temp.assert_true(public.set_report_photo(
 '00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002',
 'before','https://example.test/before','hash',9)->>'status'='conflict','Before edits remain blocked on resolved reports');
do $$ declare value text; begin
 foreach value in array array['closed','completed','rejected'] loop
   update public.reports set status=value;
   perform pg_temp.assert_true(public.set_report_photo(
    '00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002',
    'after','https://example.test/forbidden','hash',9)->>'status'='conflict',value||' must remain immutable');
 end loop;
 update public.reports set status='resolved';
 foreach value in array array['completed','cancelled'] loop
   update public.cleanup_tasks set status=value;
   begin
     perform public.set_report_photo('00000000-0000-0000-0000-000000000003',
       '00000000-0000-0000-0000-000000000002','after','https://example.test/forbidden','hash',9);
     raise exception 'Inactive task accepted evidence';
   exception when insufficient_privilege then null;
   end;
 end loop;
 update public.cleanup_tasks set status='pending';
 begin
   perform public.set_report_photo('00000000-0000-0000-0000-000000000003',
     '00000000-0000-0000-0000-000000000004','after','https://example.test/forbidden','hash',9);
   raise exception 'Unassigned actor accepted';
 exception when insufficient_privilege then null;
 end;
end $$;
