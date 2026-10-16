-- ====================================================================
-- Script: clear-reports-and-clusters.sql
-- Description: Wipes all reports, clusters, cleanup tasks, and operational
--              dependencies while strictly preserving user accounts,
--              field crew profiles, system settings, strikes, and system logs.
-- ====================================================================

BEGIN;

-- 1. Cancel active cleanup tasks so guard_report_claim allows unlinking
UPDATE public.cleanup_tasks
SET status = 'cancelled'
WHERE status::text NOT IN ('completed', 'cancelled');

-- 2. Unlink circular/self references
UPDATE public.reports 
SET cleanup_task_id = NULL, cluster_id = NULL, manual_review_id = NULL;

UPDATE public.cleanup_tasks 
SET crew_route_id = NULL, source_plan_id = NULL, cluster_id = NULL;

UPDATE public.dispatch_plans 
SET generation_job_id = NULL, optimization_run_id = NULL;

UPDATE public.plan_generation_jobs 
SET plan_id = NULL;

UPDATE public.manual_review_queue 
SET report_id = NULL;

-- 3. Delete child / operational tables in topological order
DELETE FROM public.field_load_events;
DELETE FROM public.field_task_failure_events;
DELETE FROM public.task_report_outcomes;
DELETE FROM public.report_resolution_events;
DELETE FROM public.field_assignment_receipts;
DELETE FROM public.route_waypoints;
DELETE FROM public.dispatch_access_blocks;
DELETE FROM public.dispatch_plan_items;
ALTER TABLE public.dispatch_group_commits DISABLE TRIGGER immutable_group_result;
DELETE FROM public.dispatch_group_commits;
ALTER TABLE public.dispatch_group_commits ENABLE TRIGGER immutable_group_result;

DELETE FROM public.plan_generation_jobs;
DELETE FROM public.cleanup_tasks;
DELETE FROM public.crew_routes;
DELETE FROM public.dispatch_plans;
DELETE FROM public.optimization_runs;

DELETE FROM public.manual_review_queue WHERE report_id IS NOT NULL OR strike_id IS NULL;
DELETE FROM public.notifications WHERE report_id IS NOT NULL;
DELETE FROM public.audit_logs WHERE report_id IS NOT NULL;

DELETE FROM public.reports;
DELETE FROM public.clusters;

DELETE FROM public.hotspot_accuracy;
DELETE FROM public.hotspot_predictions;
DELETE FROM public.sweeper_audit_log WHERE entity_type IN ('REPORT', 'CLUSTER', 'TASK');
DELETE FROM public.fc_operation_log;
DELETE FROM public.fc_conflict_audit;
DELETE FROM public.sync_conflicts;

COMMIT;

-- ====================================================================
-- Verification query (run to verify clean state)
-- ====================================================================
SELECT 'reports' AS table_name, count(*) AS row_count FROM public.reports
UNION ALL SELECT 'clusters', count(*) FROM public.clusters
UNION ALL SELECT 'cleanup_tasks', count(*) FROM public.cleanup_tasks
UNION ALL SELECT 'dispatch_plans', count(*) FROM public.dispatch_plans
UNION ALL SELECT 'dispatch_group_commits', count(*) FROM public.dispatch_group_commits
UNION ALL SELECT 'route_waypoints', count(*) FROM public.route_waypoints
UNION ALL SELECT 'crew_routes', count(*) FROM public.crew_routes
UNION ALL SELECT 'profiles (PRESERVED)', count(*) FROM public.profiles
UNION ALL SELECT 'field_crews (PRESERVED)', count(*) FROM public.field_crews
UNION ALL SELECT 'system_settings (PRESERVED)', count(*) FROM public.system_settings
UNION ALL SELECT 'system_logs (PRESERVED)', count(*) FROM public.system_logs;
