ALTER POLICY "Reports are viewable by authenticated users" ON public.reports USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])) OR (user_id = ( SELECT auth.uid() AS uid)) OR ((validation_status = 'approved'::report_validation_status) AND (status <> 'rejected'::report_status)) OR ((cleanup_task_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM cleanup_tasks ct
  WHERE ((ct.id = reports.cleanup_task_id) AND (( SELECT auth.uid() AS uid) = ANY (COALESCE(ct.assigned_crew_ids, '{}'::uuid[])))))))));
CREATE POLICY "Enable read access for all users" ON public.reports FOR SELECT TO anon USING (((validation_status = 'approved'::report_validation_status) AND (status <> 'rejected'::report_status)));
GRANT MAINTAIN ON public.reports TO anon;
GRANT SELECT ("id","title","description","issue_type","location","status","cluster_id","created_at","updated_at","before_photo_url","after_photo_url","stage","satisfaction_rating","lgu_resolved_at","citizen_closed_at","is_overdue","deadline_at") ON public.reports TO anon;
GRANT INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN ON public.reports_view TO anon;
GRANT SELECT ("id","title","description","issue_type","location","status","cluster_id","created_at","updated_at","before_photo_url","after_photo_url","stage","satisfaction_rating","lgu_resolved_at","citizen_closed_at","is_overdue","deadline_at") ON public.reports_view TO anon;
