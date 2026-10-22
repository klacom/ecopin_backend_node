-- Restores the captured unsafe pre-repair access ONLY for isolated recovery tests.
-- Do not deploy this rollback to live: it reopens full anonymous report reads.
BEGIN;
CREATE POLICY "Allow anon read reports" ON public.reports AS PERMISSIVE
 FOR SELECT TO anon,authenticated USING (true);
GRANT SELECT ON TABLE public.reports,public.reports_view TO anon;
NOTIFY pgrst,'reload schema';
COMMIT;
