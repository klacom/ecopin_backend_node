-- Migration: Resilient Load Heuristics & Elimination of unknown_load Defect
-- Updates commit_mixed_dispatch_plan and mixed_planning_snapshot to apply
-- safe municipal fallback archetypes rather than fatal unknown_load rejections.

-- 1. Ensure all active cleanup tasks have non-null volumetric and weight metrics
UPDATE public.cleanup_tasks
SET estimated_volume_m3 = COALESCE(estimated_volume_m3, 0.1),
    estimated_weight_kg = COALESCE(estimated_weight_kg, 10.0)
WHERE status NOT IN ('completed', 'cancelled')
  AND (estimated_volume_m3 IS NULL OR estimated_weight_kg IS NULL);

-- 2. Resilient mixed_planning_snapshot
CREATE OR REPLACE FUNCTION public.mixed_planning_snapshot()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
WITH anchors AS (
  SELECT c.id, c.priority_score, c.estimated_effort_minutes, c.recommended_task_type,
    c.created_at, extensions.st_y(c.center) AS lat, extensions.st_x(c.center) AS lng,
    coalesce((SELECT sum(coalesce(w.estimated_volume_m3, 0.10)) FROM public.reports r LEFT JOIN public.work_time_configuration w ON w.report_type=r.issue_type::text
      WHERE r.cluster_id=c.id AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')), 0.20) AS estimated_volume_m3,
    coalesce((SELECT sum(coalesce(w.estimated_weight_kg, 10.00)) FROM public.reports r LEFT JOIN public.work_time_configuration w ON w.report_type=r.issue_type::text
      WHERE r.cluster_id=c.id AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')), 20.00) AS estimated_weight_kg,
    array(SELECT r.id FROM public.reports r WHERE r.cluster_id=c.id
      AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')
      ORDER BY r.id) AS report_ids
  FROM public.clusters c
  WHERE c.status::text IN ('new','unresolved','prioritized','queued','monitoring')
    AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.cluster_id=c.id AND b.cleared_at IS NULL)
    AND NOT EXISTS(SELECT 1 FROM public.reports r JOIN public.dispatch_access_blocks b on b.report_id=r.id
      WHERE r.cluster_id=c.id AND b.cleared_at IS NULL)
  ORDER BY c.priority_score DESC NULLS LAST,c.id LIMIT 200
),
satellites AS (
  SELECT r.id, r.issue_type::text, r.lifecycle_state::text, r.severity_score, r.urgency_score,
    r.created_at, r.sla_started_at, r.deadline_at,
    extensions.st_y(r.location::extensions.geometry) AS lat,
    extensions.st_x(r.location::extensions.geometry) AS lng,
    coalesce(w.work_time_minutes, 30) AS work_time_minutes,
    coalesce(w.estimated_volume_m3, 0.05) AS estimated_volume_m3,
    coalesce(w.estimated_weight_kg, 5.00) AS estimated_weight_kg,
    exists(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=r.id AND b.cleared_at IS NULL) AS blocked
  FROM public.reports r LEFT JOIN public.work_time_configuration w ON w.report_type=r.issue_type::text
  WHERE r.status::text='unresolved' AND r.cluster_id IS NULL AND r.cleanup_task_id IS NULL
    AND r.lifecycle_state IN ('maturing','sla_breached') AND r.location IS NOT NULL
  ORDER BY r.deadline_at NULLS LAST,r.id LIMIT 200
)
SELECT jsonb_build_object(
  'anchors',coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM anchors a WHERE cardinality(a.report_ids)>0),'[]'::jsonb),
  'satellites',coalesce((SELECT jsonb_agg(to_jsonb(s)) FROM satellites s),'[]'::jsonb)
);
$$;

-- 3. Resilient commit_mixed_dispatch_plan
CREATE OR REPLACE FUNCTION public.commit_mixed_dispatch_plan(plan_id uuid, actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE plan public.dispatch_plans; anchor public.dispatch_plan_items; satellite public.dispatch_plan_items;
  crew public.field_crews; task public.cleanup_tasks; result jsonb; results jsonb:='[]'::jsonb;
  mandatory_ids uuid[]; satellite_ids uuid[]; locked_ids uuid[]; cluster_ids uuid[];
  omitted_ids uuid[]; member_count integer; claimed integer; reason text;
  group_minutes numeric; group_volume numeric; group_weight numeric; busy_minutes numeric; busy_count integer;
  busy_volume numeric; busy_weight numeric; budget numeric; shift_minutes numeric;
  crew_max_vol numeric; crew_max_wt numeric; crew_start_vol numeric; crew_start_wt numeric;
BEGIN
  PERFORM workflow_private.require_desk_actor(actor);
  SELECT * INTO plan FROM public.dispatch_plans WHERE id=plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found'; END IF;
  IF plan.mode<>'mixed' THEN RAISE EXCEPTION 'Mixed plan required'; END IF;
  IF plan.status::text='discarded' THEN RAISE EXCEPTION 'Plan discarded'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.plan_generation_jobs j WHERE j.id=plan.generation_job_id
      AND j.status='completed' AND j.plan_id=plan.id) THEN RAISE EXCEPTION 'Planning job is incomplete'; END IF;
  IF jsonb_typeof(plan.route_proposal->'routes') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Validated route proposal required'; END IF;
  PERFORM id FROM public.field_crews WHERE id IN
    (SELECT planned_crew_id FROM public.dispatch_plan_items WHERE dispatch_plan_id=plan_id AND is_selected)
    ORDER BY id FOR UPDATE;
  FOR anchor IN SELECT DISTINCT ON (group_key) * FROM public.dispatch_plan_items
      WHERE dispatch_plan_id=plan_id AND is_selected AND item_type IN ('cluster','report')
      ORDER BY group_key,id LOOP
    SELECT c.result INTO result FROM public.dispatch_group_commits c
      WHERE c.dispatch_plan_id=plan_id AND c.group_key=anchor.group_key;
    IF FOUND THEN results:=results||jsonb_build_array(result); CONTINUE; END IF;
    reason:=null;
    BEGIN
      SELECT * INTO crew FROM public.field_crews WHERE id=anchor.planned_crew_id FOR UPDATE;
      IF NOT FOUND OR crew.availability_status::text<>'available'
        OR (anchor.item_type='cluster' AND NOT crew.supports_standard)
        OR (anchor.item_type='report' AND NOT crew.supports_sweeper) THEN RAISE EXCEPTION 'crew_unavailable'; END IF;
      IF coalesce(cardinality(crew.member_profile_ids),0)=0 AND crew.team_lead_profile_id IS NULL THEN
        RAISE EXCEPTION 'crew_has_no_members'; END IF;
      IF (anchor.crew_snapshot->>'speed_factor')::numeric IS DISTINCT FROM crew.speed_factor
        OR (anchor.crew_snapshot->>'service_time_factor')::numeric IS DISTINCT FROM crew.service_time_factor THEN
        RAISE EXCEPTION 'crew_timing_changed'; END IF;

      -- Resilient crew capacity defaults by vehicle archetype
      crew_max_vol := coalesce(crew.max_volume_m3,
        CASE crew.vehicle_type::text
          WHEN 'compactor' THEN 15.0
          WHEN 'pickup' THEN 4.0
          WHEN 'tricycle' THEN 1.5
          WHEN 'motorcycle' THEN 0.3
          WHEN 'bicycle' THEN 0.15
          WHEN 'walking' THEN 0.08
          ELSE 5.0
        END);
      crew_max_wt := coalesce(crew.max_weight_kg,
        CASE crew.vehicle_type::text
          WHEN 'compactor' THEN 5000.0
          WHEN 'pickup' THEN 1200.0
          WHEN 'tricycle' THEN 350.0
          WHEN 'motorcycle' THEN 60.0
          WHEN 'bicycle' THEN 30.0
          WHEN 'walking' THEN 15.0
          ELSE 1000.0
        END);
      crew_start_vol := coalesce(crew.starting_volume_m3, 0.0);
      crew_start_wt := coalesce(crew.starting_weight_kg, 0.0);

      cluster_ids:=CASE WHEN anchor.item_type='cluster' THEN
        coalesce(nullif(anchor.cluster_ids,'{}'::uuid[]),array[anchor.cluster_id]) ELSE '{}'::uuid[] END;
      IF anchor.item_type='cluster' THEN
        SELECT count(*) INTO member_count FROM (
          SELECT c.id FROM public.clusters c WHERE c.id=ANY(cluster_ids)
            AND c.status::text IN ('new','unresolved','prioritized','queued','monitoring')
            AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.cluster_id=c.id AND b.cleared_at IS NULL)
            ORDER BY c.id FOR UPDATE SKIP LOCKED
        ) locked_clusters;
        IF member_count<>cardinality(cluster_ids) THEN RAISE EXCEPTION 'stale_anchor'; END IF;
        IF EXISTS(SELECT 1 FROM public.reports r WHERE r.cluster_id=ANY(cluster_ids)
          AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')
          AND NOT(r.id=ANY(anchor.report_ids))) THEN RAISE EXCEPTION 'anchor_membership_changed'; END IF;
      END IF;
      SELECT coalesce(array_agg(r.id ORDER BY r.id),'{}'::uuid[]) INTO mandatory_ids FROM (
        SELECT id FROM public.reports r WHERE id=ANY(anchor.report_ids) AND cleanup_task_id IS NULL
          AND status::text NOT IN ('resolved','completed','closed','rejected')
          AND ((anchor.item_type='cluster' AND cluster_id=ANY(cluster_ids))
             OR (anchor.item_type='report' AND cluster_id IS NULL AND lifecycle_state IN ('maturing','sla_breached')))
          AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=r.id AND b.cleared_at IS NULL)
          ORDER BY id FOR UPDATE SKIP LOCKED
      ) r;
      IF cardinality(mandatory_ids)<>cardinality(anchor.report_ids) THEN RAISE EXCEPTION 'stale_anchor'; END IF;
      satellite_ids:='{}'::uuid[]; omitted_ids:='{}'::uuid[];
      FOR satellite IN SELECT * FROM public.dispatch_plan_items
        WHERE dispatch_plan_id=plan_id AND group_key=anchor.group_key AND item_type='bundled_report' AND is_selected
        ORDER BY bundle_order,id LOOP
        IF satellite.planned_crew_id IS DISTINCT FROM crew.id THEN RAISE EXCEPTION 'crew_assignment_changed'; END IF;
        SELECT array_agg(r.id) INTO locked_ids FROM (
          SELECT id FROM public.reports r WHERE r.id=satellite.report_id AND r.cleanup_task_id IS NULL
            AND r.cluster_id IS NULL AND r.lifecycle_state IN ('maturing','sla_breached')
            AND r.status::text='unresolved'
            AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=r.id AND b.cleared_at IS NULL)
            FOR UPDATE SKIP LOCKED
        ) r;
        IF locked_ids IS NULL THEN
          omitted_ids:=array_append(omitted_ids,satellite.report_id);
          UPDATE public.dispatch_plan_items SET commit_disposition='omitted',commit_reason='satellite_unavailable'
            WHERE id=satellite.id;
        ELSE
          satellite_ids:=array_append(satellite_ids,satellite.report_id);
        END IF;
      END LOOP;
      group_minutes:=coalesce(anchor.estimated_duration_minutes,60)+coalesce((SELECT sum(coalesce(i.estimated_duration_minutes,30))
        FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
          AND i.report_id=ANY(satellite_ids)),0);
      group_volume:=coalesce(anchor.estimated_volume_m3,0.1)+coalesce((SELECT sum(coalesce(i.estimated_volume_m3,0.05))
        FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
          AND i.report_id=ANY(satellite_ids)),0);
      group_weight:=coalesce(anchor.estimated_weight_kg,10.0)+coalesce((SELECT sum(coalesce(i.estimated_weight_kg,5.0))
        FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
          AND i.report_id=ANY(satellite_ids)),0);

      SELECT coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*),
        coalesce(sum(coalesce(estimated_volume_m3,0.1)),0),coalesce(sum(coalesce(estimated_weight_kg,10.0)),0)
        INTO busy_minutes,busy_count,busy_volume,busy_weight FROM public.cleanup_tasks
        WHERE assigned_field_crew_id=crew.id AND status::text NOT IN ('completed','cancelled');

      shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
      IF shift_minutes<0 THEN shift_minutes:=shift_minutes+1440; END IF;
      budget:=greatest(0,(shift_minutes-coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)
        +coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))
        *coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1));
      IF busy_minutes+group_minutes>budget OR busy_count>=least(coalesce(crew.max_tasks_per_shift,10),
        coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) THEN
        RAISE EXCEPTION 'crew_capacity_changed'; END IF;
      IF crew_start_vol+busy_volume+group_volume>crew_max_vol THEN RAISE EXCEPTION 'capacity_volume'; END IF;
      IF crew_start_wt+busy_weight+group_weight>crew_max_wt THEN RAISE EXCEPTION 'capacity_weight'; END IF;
      INSERT INTO public.cleanup_tasks(cluster_id,cluster_ids,report_ids,report_sequence,satellite_report_ids,
        title,status,task_type,estimated_duration_min,estimated_work_minutes,created_by,source_plan_id,
        source_group_key,assigned_field_crew_id,dispatch_kind,route_status,routing_deadline_at,
        scheduled_date,location,priority_score,estimated_volume_m3,estimated_weight_kg)
      VALUES(anchor.cluster_id,cluster_ids,mandatory_ids||satellite_ids,mandatory_ids||satellite_ids,satellite_ids,
        CASE WHEN anchor.item_type='cluster' THEN 'Mixed cluster cleanup' ELSE 'Sweeper pickup' END,
        'pending',CASE WHEN anchor.item_type='cluster' THEN 'Mixed'::public.cleanup_task_type ELSE 'Sweeper'::public.cleanup_task_type END,
        ceil(group_minutes),anchor.estimated_work_minutes+coalesce((SELECT sum(coalesce(i.estimated_work_minutes,30))
          FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
            AND i.report_id=ANY(satellite_ids)),0),actor,plan_id,anchor.group_key,crew.id,'mixed',
        'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (SELECT location FROM public.reports WHERE id=mandatory_ids[1]),
        anchor.priority_score,group_volume,group_weight) RETURNING * INTO task;
      UPDATE public.reports SET cleanup_task_id=task.id,updated_at=now()
        WHERE id=ANY(mandatory_ids||satellite_ids) AND cleanup_task_id IS NULL;
      GET DIAGNOSTICS claimed=row_count;
      IF claimed<>cardinality(mandatory_ids)+cardinality(satellite_ids) THEN RAISE EXCEPTION 'stale_group'; END IF;
      UPDATE public.clusters SET status='scheduled' WHERE id=ANY(cluster_ids);
      UPDATE public.dispatch_plan_items SET commit_disposition='included',committed_task_id=task.id
        WHERE dispatch_plan_id=plan_id AND group_key=anchor.group_key AND is_selected
          AND (item_type<>'bundled_report' OR report_id=ANY(satellite_ids));
      result:=jsonb_build_object('status',CASE WHEN cardinality(omitted_ids)>0 THEN 'partial_commit' ELSE 'committed' end,
        'group_key',anchor.group_key,'task_id',task.id,'crew_id',crew.id,
        'report_ids',mandatory_ids||satellite_ids,'satellite_report_ids',satellite_ids,'omitted_satellite_ids',omitted_ids);
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS reason=message_text;
      IF reason NOT IN ('crew_unavailable','crew_has_no_members','crew_timing_changed','unknown_load',
        'stale_anchor','anchor_membership_changed','crew_assignment_changed','crew_capacity_changed',
        'capacity_volume','capacity_weight','stale_group','dispatch_blocked') THEN RAISE; END IF;
      result:=jsonb_build_object('status','skipped','group_key',anchor.group_key,'reason',reason);
    END;
    INSERT INTO public.dispatch_group_commits(dispatch_plan_id,group_key,result)
      VALUES(plan_id,anchor.group_key,result);
    results:=results||jsonb_build_array(result);
  END LOOP;
  UPDATE public.dispatch_plans SET status='approved' WHERE id=plan_id;
  RETURN jsonb_build_object('plan_id',plan_id,'results',results,'tasks',
    coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.cleanup_tasks t WHERE t.source_plan_id=plan_id),'[]'::jsonb));
END; $$;
