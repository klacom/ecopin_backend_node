begin;

create index if not exists clusters_center_geography_idx on public.clusters using gist ((center::extensions.geography));
create index if not exists reports_clustering_fresh_approved_idx on public.reports(created_at,id)
  where status='unresolved' and validation_status='approved' and lifecycle_state='fresh'
    and cluster_id is null and cleanup_task_id is null;

-- Keep the public reader signature after 099_remove_is_outlier; exclude unvalidated work.
create or replace function public.dbscan_reports(p_eps double precision,p_minpoints integer)
returns table(id uuid,issue_type text,location extensions.geometry,cluster_id integer)
language plpgsql security invoker set search_path='' as $$
begin
  if p_eps is null or p_eps<=0 or p_eps>10000 or p_minpoints is null or p_minpoints<2 or p_minpoints>100 then
    raise exception 'Invalid clustering parameters';
  end if;
  return query select r.id,r.issue_type::text,r.location::extensions.geometry,
    extensions.st_clusterdbscan(extensions.st_transform(r.location::extensions.geometry,32651),eps:=p_eps,minpoints:=p_minpoints)
      over(partition by r.issue_type order by r.id)
    from public.reports r
    where r.status::text='unresolved' and r.validation_status::text='approved'
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh'
      and r.location is not null and r.issue_type::text<>'pending'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null);
end; $$;

-- The same lock covers old direct callers and the new atomic clustering batch.
create or replace function public.upsert_cluster_for_reports_v2(p_report_ids uuid[],p_issue_type text,p_severity text,p_radius_meters double precision)
returns uuid language plpgsql security invoker set search_path='' as $$
declare
  locked_ids uuid[]; centroid extensions.geometry; cluster uuid; existing_ids uuid[];
  members integer; actual_radius double precision;
begin
  if p_radius_meters is null or p_radius_meters<=0 or p_radius_meters>10000 then raise exception 'Invalid clustering radius'; end if;
  if coalesce(cardinality(p_report_ids),0)=0 or cardinality(p_report_ids)<>(select count(distinct x) from unnest(p_report_ids) x) then
    raise exception 'Distinct approved reports required';
  end if;
  perform p_issue_type::public.report_issue_type, p_severity::public.cluster_severity;
  perform pg_advisory_xact_lock(884201,1);

  -- An identical retry returns the original identity without touching dispatched work.
  select array_agg(distinct r.cluster_id) into existing_ids from public.reports r
    where r.id=any(p_report_ids) and r.validation_status::text='approved' and r.issue_type::text=p_issue_type;
  if cardinality(existing_ids)=1 and existing_ids[1] is not null
    and (select count(*) from public.reports r where r.id=any(p_report_ids) and r.cluster_id=existing_ids[1]
      and r.validation_status::text='approved' and r.issue_type::text=p_issue_type)=cardinality(p_report_ids) then
    return existing_ids[1];
  end if;

  select extensions.st_centroid(extensions.st_collect(r.location::extensions.geometry)),count(*) into centroid,members
    from public.reports r where r.id=any(p_report_ids) and r.status::text='unresolved'
      and r.validation_status::text='approved' and r.issue_type::text=p_issue_type
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh' and r.location is not null
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null);
  if members<>cardinality(p_report_ids) then raise exception 'Clustering snapshot is stale or unapproved'; end if;

  -- Lock the cluster before its reports, matching dispatch's lock order.
  select c.id into cluster from public.clusters c
    where c.issue_type::text=p_issue_type and c.status::text in ('new','unresolved','prioritized')
      and extensions.st_dwithin(c.center::extensions.geography,centroid::extensions.geography,p_radius_meters)
      and not exists(select 1 from public.cleanup_tasks t where t.cluster_id=c.id or c.id=any(t.cluster_ids))
      and not exists(select 1 from public.dispatch_plan_items i where i.is_selected
        and (i.cluster_id=c.id or i.anchor_cluster_id=c.id or c.id=any(i.cluster_ids)))
      and not exists(select 1 from public.dispatch_access_blocks b where b.cluster_id=c.id and b.cleared_at is null)
      and not exists(select 1 from public.reports r where r.cluster_id=c.id
        and (r.validation_status::text is distinct from 'approved' or r.status::text is distinct from 'unresolved' or r.cleanup_task_id is not null))
    order by extensions.st_distance(c.center::extensions.geography,centroid::extensions.geography),c.created_at,c.id
    limit 1 for update of c;

  select array_agg(r.id order by r.id) into locked_ids from (
    select r.id from public.reports r where r.id=any(p_report_ids) and r.status::text='unresolved'
      and r.validation_status::text='approved' and r.issue_type::text=p_issue_type
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh' and r.location is not null
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
    order by r.id for update skip locked
  ) r;
  if coalesce(cardinality(locked_ids),0)<>cardinality(p_report_ids) then return null; end if;
  if cluster is null then
    -- A singleton may expand an existing cluster, but cannot create a new one.
    if cardinality(locked_ids)<2 then return null; end if;
    insert into public.clusters(center,issue_type,severity,status,radius_meters,report_count)
      values(centroid,p_issue_type::public.report_issue_type,p_severity::public.cluster_severity,'new',p_radius_meters,0)
      returning id into cluster;
  end if;
  update public.reports r set cluster_id=cluster,updated_at=now() where r.id=any(locked_ids);
  select extensions.st_centroid(extensions.st_collect(r.location::extensions.geometry)),count(*) into centroid,members
    from public.reports r where r.cluster_id=cluster;
  select coalesce(max(extensions.st_distance(r.location,centroid::extensions.geography)),0) into actual_radius
    from public.reports r where r.cluster_id=cluster;
  update public.clusters c set center=centroid,report_count=members,
    radius_meters=greatest(p_radius_meters,actual_radius),
    severity=(case when members>=5 then 'high' when members>=3 then 'medium' else 'low' end)::public.cluster_severity,
    updated_at=now() where c.id=cluster;
  return cluster;
end; $$;

create or replace function public.cluster_reports_incremental(p_eps double precision,p_minpoints integer)
returns table(cluster_uuid uuid,report_count integer)
language plpgsql security invoker set search_path='' as $$
declare candidate record; cluster uuid; touched uuid[]:='{}';
begin
  if p_eps is null or p_eps<=0 or p_eps>10000 or p_minpoints is null or p_minpoints<2 or p_minpoints>100 then
    raise exception 'Invalid clustering parameters';
  end if;
  perform pg_advisory_xact_lock(884201,1);
  -- Attach new single reports first; DBSCAN's minimum must not force a second nearby cluster.
  for candidate in select r.id,r.issue_type::text as issue_type from public.reports r
    where r.status::text='unresolved' and r.validation_status::text='approved'
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh'
      and r.location is not null and r.issue_type::text<>'pending'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
    order by r.created_at,r.id
  loop
    cluster:=public.upsert_cluster_for_reports_v2(array[candidate.id],candidate.issue_type,'low',p_eps);
    if cluster is not null then touched:=array_append(touched,cluster); end if;
  end loop;
  for candidate in select d.issue_type,d.cluster_id,array_agg(d.id order by d.id) as ids
    from public.dbscan_reports(p_eps,p_minpoints) d where d.cluster_id is not null
    group by d.issue_type,d.cluster_id order by d.issue_type,d.cluster_id
  loop
    cluster:=public.upsert_cluster_for_reports_v2(candidate.ids,candidate.issue_type,'low',p_eps);
    if cluster is not null then touched:=array_append(touched,cluster); end if;
  end loop;
  return query select c.id,c.report_count from public.clusters c where c.id=any(touched) order by c.id;
end; $$;

revoke all on function public.dbscan_reports(double precision,integer),
  public.upsert_cluster_for_reports_v2(uuid[],text,text,double precision),
  public.cluster_reports_incremental(double precision,integer) from public,anon,authenticated;
grant execute on function public.dbscan_reports(double precision,integer),
  public.upsert_cluster_for_reports_v2(uuid[],text,text,double precision),
  public.cluster_reports_incremental(double precision,integer) to service_role;
notify pgrst,'reload schema';
commit;
