-- Migration: 20261013130000_disassemble_dispatch_plan.sql
-- Description: Adds disassemble_dispatch_plan RPC to reset plans, undo cleanup tasks, and restore reports & clusters to the backlog

CREATE OR REPLACE FUNCTION public.disassemble_dispatch_plan(target_id uuid, actor uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  plan public.dispatch_plans;
  run public.optimization_runs;
  task_ids uuid[] := '{}';
  report_ids uuid[] := '{}';
  cluster_ids uuid[] := '{}';
  completed_count integer := 0;
  tasks_undone_count integer := 0;
  reports_reset_count integer := 0;
  clusters_reset_count integer := 0;
BEGIN
  IF actor IS NOT NULL THEN
    PERFORM workflow_private.require_desk_actor(actor);
  END IF;

  -- 1. Locate dispatch_plan and/or optimization_run
  SELECT * INTO plan FROM public.dispatch_plans 
  WHERE id = target_id OR optimization_run_id = target_id LIMIT 1;

  SELECT * INTO run FROM public.optimization_runs 
  WHERE id = target_id OR (plan.optimization_run_id IS NOT NULL AND id = plan.optimization_run_id) LIMIT 1;

  IF plan.id IS NULL AND run.id IS NULL THEN
    RAISE EXCEPTION 'Plan or optimization run not found';
  END IF;

  -- 2. Collect all cleanup tasks created for this plan or run
  SELECT coalesce(array_agg(id), '{}'::uuid[]) INTO task_ids
  FROM public.cleanup_tasks
  WHERE (plan.id IS NOT NULL AND source_plan_id = plan.id)
     OR (run.id IS NOT NULL AND crew_route_id IN (SELECT id FROM public.crew_routes WHERE optimization_run_id = run.id));

  -- 3. Check for any completed tasks
  IF cardinality(task_ids) > 0 THEN
    SELECT count(*) INTO completed_count FROM public.cleanup_tasks
    WHERE id = ANY(task_ids) AND status::text = 'completed';

    IF completed_count > 0 THEN
      RAISE EXCEPTION 'Cannot disassemble plan: % cleanup task(s) have already been completed by field crews', completed_count;
    END IF;

    -- 4. Gather affected report IDs and cluster IDs before deletion
    SELECT coalesce(array_agg(distinct r.id), '{}'::uuid[]) INTO report_ids
    FROM public.reports r WHERE r.cleanup_task_id = ANY(task_ids);

    SELECT coalesce(array_agg(distinct c.id), '{}'::uuid[]) INTO cluster_ids
    FROM public.clusters c
    WHERE c.id IN (
      SELECT distinct unnest(coalesce(t.cluster_ids, '{}'::uuid[]) || array_remove(array[t.cluster_id], null))
      FROM public.cleanup_tasks t WHERE t.id = ANY(task_ids)
    );

    -- 5. Cancel cleanup tasks first with failure_class = 'transient'.
    -- This satisfies the workflow_report_claim_guard trigger which prohibits replacing
    -- active report claims unless the task status is ('completed', 'cancelled').
    UPDATE public.cleanup_tasks
    SET status = 'cancelled'::public.task_status,
        failure_class = 'transient',
        failure_reason = 'Disassembled by officer'
    WHERE id = ANY(task_ids);

    -- 6. Disconnect and reset reports back to backlog
    UPDATE public.reports
    SET cleanup_task_id = NULL,
        status = (CASE WHEN status::text = 'in_progress' THEN 'unresolved' ELSE status::text END)::public.report_status,
        updated_at = now()
    WHERE id = ANY(report_ids);
    GET DIAGNOSTICS reports_reset_count = row_count;

    -- 6. Disconnect plan items and cleanup cascading dependencies
    UPDATE public.dispatch_plan_items
    SET committed_task_id = NULL, commit_disposition = 'omitted'
    WHERE committed_task_id = ANY(task_ids);

    DELETE FROM public.route_waypoints WHERE cleanup_task_id = ANY(task_ids);
    DELETE FROM public.dispatch_access_blocks WHERE task_id = ANY(task_ids);
    DELETE FROM public.field_task_failure_events WHERE task_id = ANY(task_ids);
    DELETE FROM public.field_load_events WHERE task_id = ANY(task_ids);
    DELETE FROM public.field_assignment_receipts WHERE task_id = ANY(task_ids);
    DELETE FROM public.report_resolution_events WHERE task_id = ANY(task_ids);
    DELETE FROM public.task_report_outcomes WHERE task_id = ANY(task_ids);

    -- 7. Reset clusters back to queued / prioritized
    IF cardinality(cluster_ids) > 0 THEN
      UPDATE public.clusters
      SET status = (CASE WHEN coalesce(priority_score, 0) > 0 THEN 'prioritized' ELSE 'queued' END)::public.cluster_status,
          updated_at = now()
      WHERE id = ANY(cluster_ids) AND status::text IN ('scheduled', 'in_progress');
      GET DIAGNOSTICS clusters_reset_count = row_count;
    END IF;

    -- 8. Delete the cleanup tasks
    DELETE FROM public.cleanup_tasks WHERE id = ANY(task_ids);
    GET DIAGNOSTICS tasks_undone_count = row_count;
  END IF;

  -- 9. Delete route waypoints & crew routes for the run if any
  IF run.id IS NOT NULL THEN
    DELETE FROM public.route_waypoints
    WHERE crew_route_id IN (SELECT id FROM public.crew_routes WHERE optimization_run_id = run.id);
    DELETE FROM public.crew_routes WHERE optimization_run_id = run.id;
    UPDATE public.optimization_runs SET status = 'discarded' WHERE id = run.id;
  END IF;

  -- 10. Update plan status
  IF plan.id IS NOT NULL THEN
    UPDATE public.dispatch_plans SET status = 'discarded' WHERE id = plan.id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'plan_id', plan.id,
    'run_id', run.id,
    'tasks_undone', tasks_undone_count,
    'reports_reset', reports_reset_count,
    'clusters_reset', clusters_reset_count,
    'message', 'Plan successfully disassembled. Tasks undone and backlog restored.'
  );
END; $$;

REVOKE ALL ON FUNCTION public.disassemble_dispatch_plan(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.disassemble_dispatch_plan(uuid, uuid) TO authenticated, service_role;
