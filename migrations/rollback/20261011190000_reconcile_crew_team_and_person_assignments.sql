-- EcoPin Rollback Migration: 20261011190000_reconcile_crew_team_and_person_assignments.sql
-- Workstream: W02 / C03 - Revert Field Crew Team IDs vs. Person IDs Reconciliation

SET LOCAL lock_timeout = '2s';

-- 1. Revert change_field_crew_member
CREATE OR REPLACE FUNCTION public.change_field_crew_member(crew_id uuid, actor uuid, member_id uuid, action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare crew public.field_crews;
begin
  perform workflow_private.require_desk_actor(actor);
  if action is null or action not in ('add','remove') or member_id is null then raise exception 'Invalid membership action'; end if;
  perform pg_advisory_xact_lock(72631010);
  select * into crew from public.field_crews where id=crew_id for update;
  if not found then raise exception 'Crew not found'; end if;
  if action='add' then
    if not exists(select 1 from public.profiles where id=member_id and role::text='field_crew') then raise exception 'Member must have field_crew role'; end if;
    if exists(select 1 from public.field_crews where id<>crew_id and (member_id=any(coalesce(member_profile_ids,'{}'::uuid[])) or team_lead_profile_id=member_id)) then raise exception 'Member already belongs to another crew'; end if;
    update public.field_crews set member_profile_ids=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])||array[member_id]) x),updated_at=now() where id=crew_id returning * into crew;
  else
    update public.field_crews set member_profile_ids=array_remove(member_profile_ids,member_id),
      team_lead_profile_id=case when team_lead_profile_id=member_id then null else team_lead_profile_id end,updated_at=now() where id=crew_id returning * into crew;
  end if;
  return to_jsonb(crew);
end; $function$;

REVOKE ALL ON FUNCTION public.change_field_crew_member(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.change_field_crew_member(uuid, uuid, uuid, text) TO postgres, service_role;

-- 2. Revert bump_task_assignment_generation
CREATE OR REPLACE FUNCTION workflow_private.bump_task_assignment_generation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
begin
  if tg_op = 'INSERT' then
    if new.assigned_field_crew_id is not null
       or cardinality(coalesce(new.assigned_crew_ids, '{}'::uuid[])) > 0 then
      new.assignment_generation := greatest(new.assignment_generation, 1);
    end if;
  elsif new.assigned_field_crew_id is distinct from old.assigned_field_crew_id
     or new.assigned_crew_ids is distinct from old.assigned_crew_ids
     or new.crew_route_id is distinct from old.crew_route_id
     or new.route_revision is distinct from old.route_revision then
    new.assignment_generation := old.assignment_generation + 1;
  else
    new.assignment_generation := old.assignment_generation;
  end if;
  return new;
end;
$$;

REVOKE ALL ON FUNCTION workflow_private.bump_task_assignment_generation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.bump_task_assignment_generation() TO postgres, service_role;

-- 3. Revert issue_task_report_receipts
CREATE OR REPLACE FUNCTION workflow_private.issue_task_report_receipts()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.assignment_generation = 0 then return new; end if;
  if tg_op = 'UPDATE' then
    if new.assignment_generation is not distinct from old.assignment_generation then return new; end if;
  end if;
    insert into public.field_assignment_receipts
      (task_id,report_id,crew_id,assignment_generation,report_claim_generation)
    select new.id,r.id,crew.id,new.assignment_generation,r.report_claim_generation
      from public.reports r
      cross join lateral unnest(coalesce(new.assigned_crew_ids,'{}'::uuid[])) crew(id)
      where r.cleanup_task_id = new.id and r.report_claim_generation > 0
    on conflict do nothing;
  return new;
end;
$function$;

REVOKE ALL ON FUNCTION workflow_private.issue_task_report_receipts() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION workflow_private.issue_task_report_receipts() TO postgres, service_role;

-- 4. Revert can_execute_task
CREATE OR REPLACE FUNCTION workflow_private.can_execute_task(actor uuid, task cleanup_tasks)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select exists(select 1 from public.profiles p where p.id=actor and
    (p.role::text in ('admin','officer') or (p.role::text='field_crew' and
      task.route_status='ready' and actor=any(coalesce(task.assigned_crew_ids,'{}'::uuid[])))));
$function$;

REVOKE ALL ON FUNCTION workflow_private.can_execute_task(uuid, cleanup_tasks) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION workflow_private.can_execute_task(uuid, cleanup_tasks) TO postgres, service_role;

-- 5. Revert workflow_task_read policy on cleanup_tasks
DROP POLICY IF EXISTS "workflow_task_read" ON public.cleanup_tasks;
CREATE POLICY "workflow_task_read" ON public.cleanup_tasks FOR SELECT TO authenticated
USING (
  (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text]))
  OR
  (((get_auth_user_role())::text = 'field_crew'::text) AND (( SELECT auth.uid() AS uid) = ANY (COALESCE(assigned_crew_ids, '{}'::uuid[])))))
);

-- 6. Revert read_authorized_cleanup_tasks
CREATE OR REPLACE FUNCTION public.read_authorized_cleanup_tasks(
  actor uuid, p_task_id uuid DEFAULT NULL, p_cluster_id uuid DEFAULT NULL,
  p_assigned_only boolean DEFAULT false, p_limit integer DEFAULT 201, p_offset integer DEFAULT 0
) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=''
AS $$
WITH viewer AS (
 SELECT id,role::text AS role FROM public.profiles WHERE id=actor
), allowed AS (
 SELECT task.*,viewer.role AS viewer_role,
   (viewer.role IN ('officer','admin') OR
    (viewer.role='field_crew' AND task.route_status='ready'
      AND task.status::text IN ('created','pending','in_progress','partially_completed')
      AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))) AS full_access
 FROM public.cleanup_tasks task CROSS JOIN viewer
 WHERE (p_task_id IS NULL OR task.id=p_task_id)
   AND (p_cluster_id IS NULL OR task.cluster_id=p_cluster_id)
   AND (NOT p_assigned_only OR actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))
   AND (
    viewer.role IN ('officer','admin')
    OR (viewer.role='field_crew' AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))
    OR (viewer.role='citizen' AND p_cluster_id IS NOT NULL AND EXISTS(
     SELECT 1 FROM public.reports r
     WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
       AND (r.user_id=actor OR (r.validation_status='approved' AND r.status<>'rejected'
        AND (r.on_private_property IS FALSE OR
          (r.on_private_property IS TRUE AND r.property_owner_consent_status='obtained'))))
    ))
   )
   AND p_limit BETWEEN 1 AND 501 AND p_offset BETWEEN 0 AND 250000
 ORDER BY task.created_at DESC NULLS LAST,task.id DESC
 LIMIT greatest(1,least(coalesce(p_limit,1),501))
 OFFSET greatest(0,least(coalesce(p_offset,0),250000))
), projected AS (
 SELECT task.created_at,task.id,
 CASE WHEN task.full_access THEN
   (to_jsonb(task)-'viewer_role'-'full_access') || jsonb_build_object(
    'clusters',CASE WHEN task.viewer_role IN ('officer','admin') THEN
       (SELECT to_jsonb(c) FROM public.clusters c WHERE c.id=task.cluster_id)
     ELSE jsonb_build_object('id',task.cluster_id) END,
    'reports',coalesce((SELECT jsonb_agg(jsonb_build_object(
     'id',r.id,'title',r.title,'description',r.description,'issue_type',r.issue_type,
     'location',r.location,'status',r.status,'report_claim_generation',r.report_claim_generation)
     ORDER BY r.id) FROM public.reports r WHERE r.cleanup_task_id=task.id),'[]'::jsonb),
    'report_claim_generations',coalesce((SELECT jsonb_object_agg(r.id::text,r.report_claim_generation)
     FROM public.reports r WHERE r.cleanup_task_id=task.id),'{}'::jsonb),
    'access_level','detail')
 ELSE jsonb_build_object(
    'id',task.id,'cluster_id',task.cluster_id,'title','Cleanup progress',
    'status',task.status,'created_at',task.created_at,'completed_at',task.completed_at,
    'is_custom',task.is_custom,'access_level','summary',
    'before_photo_url',CASE WHEN NOT EXISTS(SELECT 1
      FROM unnest(coalesce(task.report_ids,'{}'::uuid[])) AS membership(report_id)
      LEFT JOIN public.reports member_report ON member_report.id=membership.report_id
      WHERE member_report.id IS NULL)
      AND EXISTS(SELECT 1 FROM public.reports r
      WHERE r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
      AND NOT EXISTS(SELECT 1 FROM public.reports r
       WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
        AND NOT coalesce(r.user_id=actor OR
          (r.validation_status='approved' AND r.status<>'rejected' AND r.on_private_property IS FALSE),false))
      THEN task.before_photo_url ELSE NULL END,
    'after_photo_url',CASE WHEN NOT EXISTS(SELECT 1
      FROM unnest(coalesce(task.report_ids,'{}'::uuid[])) AS membership(report_id)
      LEFT JOIN public.reports member_report ON member_report.id=membership.report_id
      WHERE member_report.id IS NULL)
      AND EXISTS(SELECT 1 FROM public.reports r
      WHERE r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
      AND NOT EXISTS(SELECT 1 FROM public.reports r
       WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
        AND NOT coalesce(r.user_id=actor OR
          (r.validation_status='approved' AND r.status<>'rejected' AND r.on_private_property IS FALSE),false))
      THEN task.after_photo_url ELSE NULL END)
 END AS data FROM allowed task
)
SELECT coalesce(jsonb_agg(data ORDER BY created_at DESC NULLS LAST,id DESC),'[]'::jsonb)
FROM projected;
$$;

REVOKE ALL ON FUNCTION public.read_authorized_cleanup_tasks(uuid,uuid,uuid,boolean,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_authorized_cleanup_tasks(uuid,uuid,uuid,boolean,integer,integer) TO postgres, service_role;
