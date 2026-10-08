create function pg_temp.assert_true(value boolean, message text) returns void language plpgsql as $$
begin if value is distinct from true then raise exception 'Assertion failed: %',message; end if; end; $$;
create function pg_temp.expect_error(statement text, pattern text) returns void language plpgsql as $$
declare message text;
begin
  begin execute statement; exception when others then get stacked diagnostics message=message_text; end;
  if message is null or message not like '%'||pattern||'%' then raise exception 'Expected error %, got %',pattern,message; end if;
end; $$;

insert into profiles(id,role,full_name) values
 ('00000000-0000-0000-0000-000000000001','officer','Officer'),
 ('00000000-0000-0000-0000-000000000002','field_crew','Assigned crew'),
 ('00000000-0000-0000-0000-000000000003','field_crew','Other crew'),
 ('00000000-0000-0000-0000-000000000004','citizen','Citizen');
insert into field_crews(id,name,member_profile_ids,shift_start,shift_end,max_tasks_per_shift,supports_sweeper)
 values('00000000-0000-0000-0000-000000000010','Generalists',array['00000000-0000-0000-0000-000000000002'::uuid],'08:00','17:00',10,true);
select public.activate_report_lifecycle(12,24);
create function pg_temp.new_group(out c uuid,out r uuid) returns record language plpgsql as $$
begin
  insert into clusters(center,report_count,severity,issue_type) values(extensions.st_setsrid(extensions.st_makepoint(121,14),4326),1,'low','waste') returning id into c;
  insert into reports(cluster_id,location) values(c,extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography) returning id into r;
end; $$;
create function pg_temp.plan(c uuid,r uuid) returns uuid language plpgsql as $$
declare p jsonb;
begin
 p:=public.save_dispatch_plan('00000000-0000-0000-0000-000000000001','standard','{}',jsonb_build_array(jsonb_build_object(
  'item_type','cluster','cluster_id',c,'report_ids',array[r],'group_key','cluster:'||c,'planned_crew_id','00000000-0000-0000-0000-000000000010',
  'is_selected',true,'reason','selected','estimated_work_minutes',30,'estimated_duration_minutes',45,'priority_score',80,
  'crew_snapshot',jsonb_build_object('speed_factor',1,'service_time_factor',1))),1,495);
 return (p->>'id')::uuid;
end; $$;

do $$
declare r uuid; response jsonb; task_id uuid;
begin
  insert into public.reports(location) values(
    extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography
  ) returning id into r;
  response:=public.create_manual_cleanup_task(
    '00000000-0000-0000-0000-000000000001',array[r],
    'Officer-selected cleanup','Selected on map',
    array['00000000-0000-0000-0000-000000000002'::uuid],'high');
  task_id:=(response->'task'->>'id')::uuid;
  perform pg_temp.assert_true(response->>'status'='created','manual task created');
  perform pg_temp.assert_true((select cleanup_task_id=task_id from public.reports where id=r),
    'manual task claimed the selected report');
  perform pg_temp.assert_true((select route_status='ready' and assigned_crew_ids=array['00000000-0000-0000-0000-000000000002'::uuid]
    from public.cleanup_tasks where id=task_id),'manual assignment remains field-accessible');
  response:=public.create_manual_cleanup_task(
    '00000000-0000-0000-0000-000000000001',array[r],
    'Duplicate','Selected on map','{}'::uuid[],null);
  perform pg_temp.assert_true(response->>'status'='conflict','manual task cannot reclaim report');
  perform pg_temp.assert_true((select count(*)=1 from public.cleanup_tasks where r=any(report_ids)),
    'conflict creates no second task');
end $$;

do $$ declare c uuid;r uuid;p uuid;p2 uuid;t uuid; result jsonb;again jsonb;version bigint;lease jsonb;routes jsonb;run jsonb;block uuid;
begin
 select * into c,r from pg_temp.new_group(); p:=pg_temp.plan(c,r);p2:=pg_temp.plan(c,r);
 result:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');t:=(result->'tasks'->0->>'id')::uuid;
 perform pg_temp.assert_true(t is not null,'task created');
 perform pg_temp.assert_true((select cleanup_task_id=t and lifecycle_state='dispatched' from reports where id=r),'atomic report claim');
 again:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');
 perform pg_temp.assert_true(again->'results'=result->'results','immutable replay');
 again:=public.commit_dispatch_plan(p2,'00000000-0000-0000-0000-000000000001');
 perform pg_temp.assert_true(again->'results'->0->>'reason'='stale_anchor','overlap rejects claimed anchor');
 perform pg_temp.assert_true((select count(*)=1 from cleanup_tasks where r=any(report_ids)),'no double assignment');
 perform pg_temp.expect_error(format('update reports set cleanup_task_id=null where id=%L',r),'Active report claim');
 perform pg_temp.expect_error(format('update reports set cluster_id=null where id=%L',r),'Active report claim');
 perform pg_temp.expect_error(format('update dispatch_group_commits set result=''{}'' where dispatch_plan_id=%L',p),'immutable');
 perform pg_temp.expect_error(format('select public.submit_task_outcome(%L,%L,''completed'','''')',t,'00000000-0000-0000-0000-000000000003'),'access denied');
 perform pg_temp.expect_error(format('select public.submit_task_outcome(%L,%L,''completed'','''')',t,'00000000-0000-0000-0000-000000000002'),'access denied');
 lease:=public.begin_plan_routing(p,'00000000-0000-0000-0000-000000000001');
 perform pg_temp.assert_true(public.begin_plan_routing(p,'00000000-0000-0000-0000-000000000001')->>'running'='true','routing lease coordinates workers');
 routes:=jsonb_build_array(jsonb_build_object('crew_id','00000000-0000-0000-0000-000000000010','task_ids',array[t],
  'speed_factor',1,'service_time_factor',1,'totalDistance',200,'approximate',true,'waypoints',jsonb_build_array(
  jsonb_build_object('sequence_order',0,'latitude',14,'longitude',121,'waypoint_type','depot_start','distance_from_previous_meters',0,'estimated_time_from_previous_min',0),
  jsonb_build_object('sequence_order',1,'latitude',14,'longitude',121,'waypoint_type','task','cleanup_task_id',t,'distance_from_previous_meters',100,'estimated_time_from_previous_min',1),
  jsonb_build_object('sequence_order',2,'latitude',14,'longitude',121,'waypoint_type','depot_end','distance_from_previous_meters',100,'estimated_time_from_previous_min',1))));
 run:=public.publish_dispatch_routes(p,'00000000-0000-0000-0000-000000000001',(lease->>'token')::uuid,routes,'{"latitude":14,"longitude":121}');
 perform pg_temp.assert_true(run->>'run_id' is not null,'route published');
 perform pg_temp.assert_true((select route_status='ready' and estimated_duration_min=32 and cardinality(assigned_crew_ids)=1 from cleanup_tasks where id=t),'publication includes work and return travel');
 perform pg_temp.assert_true((select count(*)=3 from route_waypoints),'return depot waypoint persisted');
 perform pg_temp.assert_true(public.publish_dispatch_routes(p,'00000000-0000-0000-0000-000000000001',null,'[]','{}')->>'alreadyPublished'='true','publication replay');
 select fc_version into version from reports where id=r;
 result:=public.apply_fc_operation('00000000-0000-0000-0000-000000000002','op-first','fc.report.update_status',r,'report','{"status":"in_progress"}',version);
 perform pg_temp.assert_true(result->>'status'='success','assigned mobile write');
 again:=public.apply_fc_operation('00000000-0000-0000-0000-000000000002','op-stale','fc.report.update_status',r,'report','{"status":"resolved"}',version);
 perform pg_temp.assert_true(again->>'status'='conflict','stale mobile write rejected');
 perform pg_temp.assert_true((select count(*)=1 from fc_conflict_audit),'conflict audit atomic');
 perform pg_temp.assert_true(public.apply_fc_operation('00000000-0000-0000-0000-000000000002','op-first','fc.report.update_status',r,'report','{"status":"in_progress"}',version)->>'replayed'='true','operation replay');
 perform pg_temp.expect_error(format('select public.apply_fc_operation(%L,''op-foreign'',''fc.report.update_details'',%L,''report'',''{"notes":"x"}'',0)','00000000-0000-0000-0000-000000000003',r),'not assigned');
 perform pg_temp.expect_error(format('select public.apply_fc_operation(%L,''op-owned'',''fc.report.update_details'',%L,''report'',''{"is_outlier":true}'',0)','00000000-0000-0000-0000-000000000002',r),'server-owned');
 perform pg_temp.expect_error(format('select public.submit_task_outcome(%L,%L,''unable_to_complete'',''blocked'')',t,'00000000-0000-0000-0000-000000000002'),'classification');
 result:=public.submit_task_outcome(t,'00000000-0000-0000-0000-000000000002','unable_to_complete','Road flooded','site');
 perform pg_temp.assert_true((select cleanup_task_id is null and cluster_id=c and status='unresolved' from reports where id=r),'failure releases claim and keeps cluster');
 perform pg_temp.assert_true((select status='deferred' from clusters where id=c),'site failure deferred');
 select id into block from dispatch_access_blocks where cluster_id=c and cleared_at is null;
 perform pg_temp.assert_true(block is not null,'site block persisted');
 perform pg_temp.expect_error(format('update clusters set status=''prioritized'' where id=%L',c),'clearance');
 perform public.clear_dispatch_block(block,'00000000-0000-0000-0000-000000000001','Road reopened');
 perform pg_temp.assert_true((select status='prioritized' from clusters where id=c),'officer clearance requeues');
 p:=pg_temp.plan(c,r); result:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');t:=(result->'tasks'->0->>'id')::uuid;
 update cleanup_tasks set routing_deadline_at=now()-interval '1 second' where id=t;
 perform pg_temp.assert_true(public.expire_unpublished_dispatch_claims()->>'expiredCount'='1','unpublished claims expire');
 perform pg_temp.assert_true((select cleanup_task_id is null and cluster_id=c from reports where id=r),'expiry releases report');
 perform pg_temp.assert_true((select status='prioritized' from clusters where id=c),'transient expiry requeues intact cluster');
 select * into c,r from pg_temp.new_group();p:=pg_temp.plan(c,r);
 update reports set status='closed' where id=r;
 result:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');
 perform pg_temp.assert_true(result->'results'->0->>'reason'='stale_group','stale mandatory group rolls back');
 perform pg_temp.assert_true((select count(*)=0 from cleanup_tasks where source_plan_id=p),'stale group creates no task');
 perform pg_temp.assert_true(not has_function_privilege('authenticated','public.commit_dispatch_plan(uuid,uuid)','execute'),'clients cannot call service RPC');
 perform pg_temp.assert_true(not has_table_privilege('authenticated','public.cleanup_tasks','update'),'clients cannot bypass task authority');
 perform pg_temp.assert_true(not has_column_privilege('authenticated','public.profiles','role','update'),'self role escalation denied');
end; $$;

do $$ declare c uuid;r uuid;p uuid;t uuid;result jsonb;version bigint;block uuid;other uuid;
begin
  select * into c,r from pg_temp.new_group();p:=pg_temp.plan(c,r);
  update field_crews set service_time_factor=2 where id='00000000-0000-0000-0000-000000000010';
  result:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');
  perform pg_temp.assert_true(result->'results'->0->>'reason'='crew_timing_changed','stale fleet estimates rejected');
  update field_crews set service_time_factor=1 where id='00000000-0000-0000-0000-000000000010';
  p:=pg_temp.plan(c,r);result:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');t:=(result->'tasks'->0->>'id')::uuid;
  perform pg_temp.expect_error(format('insert into reports(cluster_id) values(%L)',c),'Cannot add reports');
  update cleanup_tasks set route_status='ready',assigned_crew_ids=array['00000000-0000-0000-0000-000000000002'::uuid],assigned_at=now() where id=t;
  select fc_version into version from reports where id=r;
  result:=public.apply_fc_operation('00000000-0000-0000-0000-000000000002','future-version','fc.report.update_details',r,'report','{"notes":"future"}',version+100);
  perform pg_temp.assert_true(result->>'status'='conflict','future versions rejected too');
  result:=public.set_report_photo(r,'00000000-0000-0000-0000-000000000002','before','https://example.test/evidence','sha',version);
  perform pg_temp.assert_true(result->>'status'='success','assigned report photo accepted');
  result:=public.set_report_photo(r,'00000000-0000-0000-0000-000000000002','after','https://example.test/late','sha',version);
  perform pg_temp.assert_true(result->>'status'='conflict','report photo rejects stale version');
  perform pg_temp.expect_error(format('select public.set_report_photo(%L,%L,''after'',''https://example.test/foreign'',''sha'',%s)',r,'00000000-0000-0000-0000-000000000003',version+1),'not assigned');
  perform public.apply_fc_operation('00000000-0000-0000-0000-000000000002','note-1','fc.note.add',r,'report','{"action":"First note"}',0);
  perform public.apply_fc_operation('00000000-0000-0000-0000-000000000002','note-2','fc.note.add',r,'report','{"action":"Second note"}',0);
  perform public.apply_fc_operation('00000000-0000-0000-0000-000000000002','note-1','fc.note.add',r,'report','{"action":"First note"}',0);
  perform pg_temp.assert_true((select count(*)=2 from response_log where report_id=r),'notes additive with atomic replay');
  select fc_version into version from cleanup_tasks where id=t;
  result:=public.set_task_photo(t,'00000000-0000-0000-0000-000000000002','before','https://example.test/photo','hash',version);
  perform pg_temp.assert_true(result->>'status'='success','assigned photo write succeeds');
  result:=public.set_task_photo(t,'00000000-0000-0000-0000-000000000002','after','https://example.test/other','hash',version);
  perform pg_temp.assert_true(result->>'status'='conflict','photo version check is atomic');
  perform public.submit_task_outcome(t,'00000000-0000-0000-0000-000000000002','cleanup_completed','Cleaned');
  perform pg_temp.assert_true((select status='resolved' and lgu_resolved_at is not null and cleanup_task_id is null from reports where id=r),'physical cleanup records resolution and releases claims');
  perform pg_temp.assert_true(public.submit_task_outcome(t,'00000000-0000-0000-0000-000000000002','completed','')->>'status'='duplicate','completed retry idempotent');
  select * into c,r from pg_temp.new_group();p:=pg_temp.plan(c,r);result:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');t:=(result->'tasks'->0->>'id')::uuid;
  perform public.submit_task_outcome(t,'00000000-0000-0000-0000-000000000001','issue_not_found','No active issue');
  perform pg_temp.assert_true((select status='closed' and lgu_resolved_at is null from reports where id=r),'closed does not fabricate cleanup');
  insert into reports(location) values(extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography) returning id into r;
  set local session_replication_role=replica;
  update reports set sla_started_at=now()-interval '25 hours',deadline_at=now()+interval '23 hours',lifecycle_state='maturing',matured_at=now()-interval '1 hour' where id=r;
  set local session_replication_role=origin;
  result:=public.save_dispatch_plan('00000000-0000-0000-0000-000000000001','sweeper','{}',jsonb_build_array(jsonb_build_object(
    'item_type','report','report_id',r,'report_ids',array[r],'group_key','report:'||r,'planned_crew_id','00000000-0000-0000-0000-000000000010',
    'is_selected',true,'reason','selected','estimated_work_minutes',30,'estimated_duration_minutes',45,'crew_snapshot','{"speed_factor":1,"service_time_factor":1}'::jsonb)),1,495);
  p:=(result->>'id')::uuid;result:=public.commit_dispatch_plan(p,'00000000-0000-0000-0000-000000000001');t:=(result->'tasks'->0->>'id')::uuid;
  perform pg_temp.assert_true((select task_type::text='Sweeper' and dispatch_kind='sweeper' and cluster_id is null from cleanup_tasks where id=t),'standalone sweeper dispatch works');
  perform public.submit_task_outcome(t,'00000000-0000-0000-0000-000000000001','unable_to_complete','Hazardous site','safety');
  perform pg_temp.assert_true((select count(*)=1 from dispatch_access_blocks where report_id=r and cleared_at is null),'standalone safety block excludes sweeper pool');
  insert into reports(location) values(extensions.st_setsrid(extensions.st_makepoint(121.01,14),4326)::extensions.geography) returning id into r;
  insert into reports(location) values(extensions.st_setsrid(extensions.st_makepoint(121.0101,14),4326)::extensions.geography) returning id into other;
  c:=public.upsert_cluster_for_reports_v2(array[r,other],'waste','low',50);
  perform pg_temp.assert_true((select count(*)=2 from reports where cluster_id=c),'fresh reports cluster atomically');
  perform pg_temp.assert_true((select count(*)=0 from public.dbscan_reports(50,2) where id in (r,other)),'existing members excluded from reclustering');
  perform pg_temp.expect_error(format('select public.upsert_cluster_for_reports_v2(array[%L::uuid,%L::uuid],''waste'',''low'',50)',r,other),'stale');
end; $$;

-- Exercise database permissions as the actual API roles, not only as superuser.
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
select pg_temp.assert_true((select count(*)=0 from public.cleanup_tasks),'citizen cannot read crew tasks');
select pg_temp.assert_true((select reloptions @> array['security_invoker=true'] from pg_class where oid='public.reports_view'::regclass),'report view uses caller permissions');
select pg_temp.expect_error('update public.reports set is_outlier=true where id is null','permission denied');
select pg_temp.expect_error('update public.reports_view set is_outlier=true where id is null','permission denied');
select pg_temp.expect_error('select public.commit_dispatch_plan(gen_random_uuid(),gen_random_uuid())','permission denied');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select pg_temp.assert_true((select count(*)>0 from public.cleanup_tasks),'assigned field crew can read tasks');
select pg_temp.assert_true((select count(*)>0 from public.field_crews),'member can read own crew');
reset role;
set role service_role;
select pg_temp.assert_true((select public.save_dispatch_plan('00000000-0000-0000-0000-000000000001','standard','{}','[]',0,0)->>'id' is not null),'service role can execute desk RPC');
reset role;
