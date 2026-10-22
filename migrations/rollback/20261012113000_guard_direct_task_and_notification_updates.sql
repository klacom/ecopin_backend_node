-- Rollback migration: 20261012113000_guard_direct_task_and_notification_updates.sql

SET LOCAL lock_timeout = '2s';

DROP TRIGGER IF EXISTS guard_notification_update ON public.notifications;
DROP FUNCTION IF EXISTS workflow_private.guard_notification_update();

DROP TRIGGER IF EXISTS guard_task_direct_update ON public.cleanup_tasks;
DROP FUNCTION IF EXISTS workflow_private.guard_task_direct_update();

DROP POLICY IF EXISTS "Field Crew, Officers, and Admins can update cleanup tasks" ON public.cleanup_tasks;
CREATE POLICY "Field Crew, Officers, and Admins can update cleanup tasks" ON public.cleanup_tasks
FOR UPDATE TO authenticated
USING (get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role]))
WITH CHECK (get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role]));

REVOKE UPDATE ON public.cleanup_tasks FROM authenticated;

