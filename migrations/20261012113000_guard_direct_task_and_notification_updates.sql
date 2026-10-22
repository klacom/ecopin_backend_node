-- Migration: 20261012113000_guard_direct_task_and_notification_updates.sql
-- Description: Enforces assignment-scoped UPDATE policy on cleanup_tasks for field_crew,
--              guards immutable task orchestration fields against direct tampering,
--              and restricts notification updates to is_read only.

SET LOCAL lock_timeout = '2s';

-- 1. Tighten cleanup_tasks UPDATE policy to enforce crew assignment and active ready status
GRANT UPDATE ON public.cleanup_tasks TO authenticated;

DROP POLICY IF EXISTS "Field Crew, Officers, and Admins can update cleanup tasks" ON public.cleanup_tasks;
CREATE POLICY "Field Crew, Officers, and Admins can update cleanup tasks" ON public.cleanup_tasks
FOR UPDATE TO authenticated
USING (
  ((SELECT public.get_auth_user_role())::text IN ('admin', 'officer'))
  OR (((SELECT public.get_auth_user_role())::text = 'field_crew')
      AND ((SELECT auth.uid()) = ANY(coalesce(assigned_crew_ids, '{}'::uuid[])))
      AND route_status = 'ready'
      AND status::text IN ('created', 'pending', 'in_progress', 'partially_completed'))
)
WITH CHECK (
  ((SELECT public.get_auth_user_role())::text IN ('admin', 'officer'))
  OR (((SELECT public.get_auth_user_role())::text = 'field_crew')
      AND ((SELECT auth.uid()) = ANY(coalesce(assigned_crew_ids, '{}'::uuid[])))
      AND route_status = 'ready'
      AND status::text IN ('created', 'pending', 'in_progress', 'partially_completed', 'completed'))
);

-- 2. Trigger function to protect immutable orchestration fields on cleanup_tasks
CREATE OR REPLACE FUNCTION workflow_private.guard_task_direct_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  jwt_role text;
  caller_role text;
BEGIN
  jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  IF jwt_role = 'service_role' THEN
    RETURN new;
  END IF;

  IF coalesce(current_setting('role', true), 'postgres') NOT IN ('anon', 'authenticated')
     AND jwt_role = ''
     AND (SELECT auth.uid()) IS NULL THEN
    RETURN new;
  END IF;

  caller_role := (SELECT public.get_auth_user_role())::text;

  IF new.source_plan_id IS DISTINCT FROM old.source_plan_id THEN
    RAISE EXCEPTION 'source_plan_id cannot be modified directly' USING ERRCODE = '42501';
  END IF;
  IF new.created_by IS DISTINCT FROM old.created_by THEN
    RAISE EXCEPTION 'created_by cannot be modified directly' USING ERRCODE = '42501';
  END IF;

  IF caller_role = 'field_crew' THEN
    IF new.cluster_id IS DISTINCT FROM old.cluster_id THEN
      RAISE EXCEPTION 'cluster_id cannot be modified by field crew' USING ERRCODE = '42501';
    END IF;
    IF new.assigned_crew_ids IS DISTINCT FROM old.assigned_crew_ids THEN
      RAISE EXCEPTION 'assigned_crew_ids cannot be modified by field crew' USING ERRCODE = '42501';
    END IF;
    IF new.assignment_generation IS DISTINCT FROM old.assignment_generation THEN
      RAISE EXCEPTION 'assignment_generation cannot be modified by field crew' USING ERRCODE = '42501';
    END IF;
    IF new.report_ids IS DISTINCT FROM old.report_ids THEN
      RAISE EXCEPTION 'report_ids cannot be modified by field crew' USING ERRCODE = '42501';
    END IF;
    IF new.route_status IS DISTINCT FROM old.route_status THEN
      RAISE EXCEPTION 'route_status cannot be modified by field crew' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN new;
END;
$$;

REVOKE ALL ON FUNCTION workflow_private.guard_task_direct_update() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.guard_task_direct_update() TO postgres, service_role;

DROP TRIGGER IF EXISTS guard_task_direct_update ON public.cleanup_tasks;
CREATE TRIGGER guard_task_direct_update
BEFORE UPDATE ON public.cleanup_tasks
FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_task_direct_update();

-- 3. Trigger function to restrict notification updates to is_read only
CREATE OR REPLACE FUNCTION workflow_private.guard_notification_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  jwt_role text;
BEGIN
  jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  IF jwt_role = 'service_role' THEN
    RETURN new;
  END IF;

  IF coalesce(current_setting('role', true), 'postgres') NOT IN ('anon', 'authenticated')
     AND jwt_role = ''
     AND (SELECT auth.uid()) IS NULL THEN
    RETURN new;
  END IF;

  IF new.id IS DISTINCT FROM old.id
     OR new.user_id IS DISTINCT FROM old.user_id
     OR new.report_id IS DISTINCT FROM old.report_id
     OR new.type IS DISTINCT FROM old.type
     OR new.title IS DISTINCT FROM old.title
     OR new.body IS DISTINCT FROM old.body
     OR new.created_at IS DISTINCT FROM old.created_at THEN
    RAISE EXCEPTION 'Only is_read can be updated on notifications' USING ERRCODE = '42501';
  END IF;

  RETURN new;
END;
$$;

REVOKE ALL ON FUNCTION workflow_private.guard_notification_update() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.guard_notification_update() TO postgres, service_role;

DROP TRIGGER IF EXISTS guard_notification_update ON public.notifications;
CREATE TRIGGER guard_notification_update
BEFORE UPDATE ON public.notifications
FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_notification_update();

