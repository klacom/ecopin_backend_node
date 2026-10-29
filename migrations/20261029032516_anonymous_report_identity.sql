-- PDT-20. Keep private ownership and audit attribution; constrain all client read paths.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE SCHEMA IF NOT EXISTS privacy_private;
REVOKE ALL ON SCHEMA privacy_private FROM PUBLIC,anon,authenticated;
ALTER TABLE public.reports ADD COLUMN hide_identity boolean NOT NULL DEFAULT false;
-- A privacy tombstone survives withdrawal, so old audit/sync records stay protected.
CREATE TABLE privacy_private.hidden_report_owners(report_id uuid PRIMARY KEY,owner_id uuid NOT NULL);
CREATE TABLE privacy_private.hidden_report_artifacts(record_id uuid PRIMARY KEY,report_id uuid NOT NULL REFERENCES privacy_private.hidden_report_owners(report_id));
ALTER TABLE privacy_private.hidden_report_artifacts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON privacy_private.hidden_report_artifacts FROM PUBLIC,anon,authenticated;
GRANT SELECT ON privacy_private.hidden_report_artifacts TO service_role;
ALTER TABLE privacy_private.hidden_report_owners ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON privacy_private.hidden_report_owners FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA privacy_private TO service_role;
GRANT SELECT ON privacy_private.hidden_report_owners TO service_role;
CREATE FUNCTION privacy_private.protect_report_identity() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF TG_OP='INSERT' AND NEW.hide_identity AND (SELECT auth.role()) IN ('anon','authenticated') THEN
  RAISE EXCEPTION 'Submit hidden reports through the protected API' USING ERRCODE='42501';
 END IF;
 IF TG_OP='INSERT' AND EXISTS(SELECT 1 FROM privacy_private.hidden_report_owners WHERE report_id=NEW.id) THEN
  RAISE EXCEPTION 'Report identity cannot be reused' USING ERRCODE='23505';
 END IF;
 IF TG_OP='UPDATE' AND OLD.hide_identity AND NEW.user_id IS DISTINCT FROM OLD.user_id AND (NEW.user_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.profiles WHERE id=OLD.user_id)) THEN
  RAISE EXCEPTION 'Hidden report ownership cannot be reassigned' USING ERRCODE='22023';
 END IF;
 IF TG_OP='UPDATE' AND NEW.hide_identity IS DISTINCT FROM OLD.hide_identity THEN
  RAISE EXCEPTION 'hide_identity is immutable after submission' USING ERRCODE='22023';
 END IF;
 IF NEW.hide_identity AND NEW.user_id IS NOT NULL THEN
  INSERT INTO privacy_private.hidden_report_owners VALUES(NEW.id,NEW.user_id) ON CONFLICT DO NOTHING;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION privacy_private.protect_report_identity() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER protect_report_identity BEFORE INSERT OR UPDATE ON public.reports
 FOR EACH ROW EXECUTE FUNCTION privacy_private.protect_report_identity();

CREATE FUNCTION privacy_private.capture_hidden_report_references() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE t record;
BEGIN
 IF OLD.hide_identity THEN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN ('audit_logs','manual_review_queue','notifications','evidences','strikes','fc_conflict_audit')
    AND EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=c.oid AND attname='report_id' AND NOT attisdropped)
    AND EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=c.oid AND attname='id' AND atttypid='uuid'::regtype AND NOT attisdropped) LOOP
   EXECUTE format('INSERT INTO privacy_private.hidden_report_artifacts SELECT id,$1 FROM public.%I WHERE report_id=$1 ON CONFLICT DO NOTHING',t.relname) USING OLD.id;
  END LOOP;
 END IF;
 RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION privacy_private.capture_hidden_report_references() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER capture_hidden_report_references BEFORE DELETE ON public.reports FOR EACH ROW EXECUTE FUNCTION privacy_private.capture_hidden_report_references();

CREATE FUNCTION privacy_private.identity_readable(target uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT NOT EXISTS(SELECT 1 FROM privacy_private.hidden_report_owners h WHERE (h.report_id=target OR h.report_id IN (SELECT report_id FROM privacy_private.hidden_report_artifacts WHERE record_id=target))
  AND h.owner_id IS DISTINCT FROM (SELECT auth.uid()));
$$;
CREATE FUNCTION privacy_private.operational_readable(target uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT (SELECT auth.role())='service_role' OR EXISTS(
  SELECT 1 FROM public.reports r JOIN public.profiles p ON p.id=(SELECT auth.uid())
  WHERE r.id=target AND (r.user_id=p.id OR p.role::text IN ('officer','admin') OR
   (p.role::text='field_crew' AND EXISTS(SELECT 1 FROM public.cleanup_tasks t
    WHERE t.id=r.cleanup_task_id AND t.route_status='ready'
     AND t.status::text IN ('created','pending','in_progress','partially_completed')
     AND (p.id=ANY(coalesce(t.assigned_crew_ids,'{}'::uuid[])) OR EXISTS(
      SELECT 1 FROM public.field_crews f WHERE f.id=t.assigned_field_crew_id
       AND (f.team_lead_profile_id=p.id OR p.id=ANY(coalesce(f.member_profile_ids,'{}'::uuid[])))
     ))))));
$$;
REVOKE ALL ON FUNCTION privacy_private.identity_readable(uuid),privacy_private.operational_readable(uuid) FROM PUBLIC;
GRANT USAGE ON SCHEMA privacy_private TO anon,authenticated;
GRANT EXECUTE ON FUNCTION privacy_private.identity_readable(uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION privacy_private.operational_readable(uuid) TO authenticated,service_role;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY hidden_report_raw_read ON public.reports AS RESTRICTIVE FOR SELECT TO anon,authenticated
 USING (privacy_private.identity_readable(id));

-- Invoker views cannot recover rows denied by caller RLS. Use a constrained read role,
-- with explicit per-request authorization on its own policy and masked columns in the view.
CREATE ROLE ecopin_operational_reader NOLOGIN NOINHERIT NOBYPASSRLS;
GRANT ecopin_operational_reader TO postgres;
GRANT USAGE ON SCHEMA public,privacy_private TO ecopin_operational_reader;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='extensions') THEN GRANT USAGE ON SCHEMA extensions TO ecopin_operational_reader; END IF; END $$;
GRANT SELECT ON public.reports TO ecopin_operational_reader;
GRANT EXECUTE ON FUNCTION privacy_private.operational_readable(uuid) TO ecopin_operational_reader;
CREATE POLICY operational_view_rows ON public.reports FOR SELECT TO ecopin_operational_reader
 USING (privacy_private.operational_readable(id));
DO $$ DECLARE cols text; old_definition text; BEGIN
 old_definition:=rtrim(pg_get_viewdef('public.reports_view'::regclass,true),E';\n ');
 SELECT string_agg(CASE WHEN a.attname IN ('user_id','idempotency_key','profiles','user_full_name','reporter_id','reporter_name','reporter_email','reporter_phone','photo_lat','photo_lng','photo_accuracy','photo_captured_at','photo_source','is_mocked')
  THEN format('CASE WHEN r.hide_identity THEN NULL::%s ELSE v.%I END AS %I',format_type(a.atttypid,a.atttypmod),a.attname,a.attname)
  ELSE format('v.%I',a.attname) END,',' ORDER BY a.attnum) INTO cols
 FROM pg_attribute a WHERE a.attrelid='public.reports_view'::regclass AND a.attnum>0 AND NOT a.attisdropped;
 EXECUTE 'CREATE OR REPLACE VIEW public.reports_view WITH (security_barrier=true,security_invoker=false) AS SELECT '
  ||cols||',r.hide_identity FROM ('||old_definition||') v JOIN public.reports r ON r.id=v.id';
END $$;
GRANT CREATE ON SCHEMA public TO ecopin_operational_reader;
ALTER VIEW public.reports_view OWNER TO ecopin_operational_reader;
REVOKE CREATE ON SCHEMA public FROM ecopin_operational_reader;
REVOKE ALL ON public.reports_view FROM PUBLIC,anon;
GRANT SELECT ON public.reports_view TO authenticated,service_role;

-- Restrict raw related-table access too. A definer helper avoids NOT EXISTS / RLS blindness.
DO $$ DECLARE t record; predicate text; BEGIN
 FOR t IN SELECT c.oid,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN
 ('audit_logs','evidences','notifications','strikes','manual_review_queue','fc_operation_log','fc_conflict_audit','sweeper_audit_log') LOOP
  IF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=t.oid AND attname='report_id' AND NOT attisdropped) THEN
   predicate:='(report_id IS NULL OR privacy_private.identity_readable(report_id))';
   IF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=t.oid AND attname='id' AND atttypid='uuid'::regtype AND NOT attisdropped) THEN
    predicate:=predicate||' AND privacy_private.identity_readable(id)';
   END IF;
  ELSIF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=t.oid AND attname='entity_type' AND NOT attisdropped)
   AND EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=t.oid AND attname='entity_id' AND atttypid='uuid'::regtype AND NOT attisdropped) THEN
   predicate:='lower(entity_type::text) IS DISTINCT FROM ''report'' OR privacy_private.identity_readable(entity_id)';
  ELSE
   -- Logs with opaque JSON snapshots have no safe client projection. APIs use service-role reads.
   EXECUTE format('REVOKE ALL ON public.%I FROM anon,authenticated',t.relname);
   EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t.relname);
   EXECUTE format('CREATE POLICY hidden_unstructured_read ON public.%I AS RESTRICTIVE FOR SELECT TO anon,authenticated USING (false)',t.relname);
   CONTINUE;
  END IF;
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t.relname);
  EXECUTE format('CREATE POLICY hidden_report_related_read ON public.%I AS RESTRICTIVE FOR SELECT TO anon,authenticated USING (%s)',t.relname,predicate);
 END LOOP;
END $$;

-- Query-time masking prevents author filters/counts from associating hidden reports.
GRANT SELECT ON public.audit_logs TO ecopin_operational_reader;
CREATE POLICY operational_activity_rows ON public.audit_logs FOR SELECT TO ecopin_operational_reader USING (
 (SELECT auth.role())='service_role' OR (report_id IS NOT NULL AND privacy_private.operational_readable(report_id))
 OR (report_id IS NULL AND (SELECT public.get_auth_user_role())::text IN ('officer','admin')));
DO $$ DECLARE cols text; BEGIN
 SELECT string_agg(CASE WHEN a.attname IN ('user_id','metadata','action_details')
  THEN format('CASE WHEN h.report_id IS NOT NULL AND (%L=''metadata'' OR a.user_id=h.owner_id) THEN NULL::%s ELSE a.%I END AS %I',a.attname,format_type(a.atttypid,a.atttypmod),a.attname,a.attname)
  ELSE format('a.%I',a.attname) END,',' ORDER BY a.attnum) INTO cols
 FROM pg_attribute a WHERE a.attrelid='public.audit_logs'::regclass AND a.attnum>0 AND NOT a.attisdropped;
 EXECUTE 'CREATE VIEW public.report_activity_view WITH (security_barrier=true,security_invoker=false) AS SELECT '||cols||' FROM public.audit_logs a LEFT JOIN privacy_private.hidden_report_owners h ON h.report_id=coalesce(a.report_id,(SELECT x.report_id FROM privacy_private.hidden_report_artifacts x WHERE x.record_id=a.id))';
END $$;
GRANT SELECT ON privacy_private.hidden_report_owners,privacy_private.hidden_report_artifacts TO ecopin_operational_reader;
CREATE POLICY internal_privacy_artifact_read ON privacy_private.hidden_report_artifacts FOR SELECT TO ecopin_operational_reader USING (true);
CREATE POLICY internal_privacy_view_read ON privacy_private.hidden_report_owners FOR SELECT TO ecopin_operational_reader USING (true);
GRANT CREATE ON SCHEMA public TO ecopin_operational_reader;
ALTER VIEW public.report_activity_view OWNER TO ecopin_operational_reader;
REVOKE CREATE ON SCHEMA public FROM ecopin_operational_reader;
REVOKE ALL ON public.report_activity_view FROM PUBLIC,anon;
GRANT SELECT ON public.report_activity_view TO authenticated,service_role;

-- Preserve private strike links before withdrawal deletes a manual-review queue row.
CREATE FUNCTION privacy_private.capture_hidden_queue_reference() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE item jsonb; target uuid; strike uuid;
BEGIN
 item:=CASE WHEN TG_OP='INSERT' THEN to_jsonb(NEW) ELSE to_jsonb(OLD) END;
 target:=nullif(item->>'report_id','')::uuid;
 IF target IS NULL THEN SELECT report_id INTO target FROM privacy_private.hidden_report_artifacts WHERE record_id=(item->>'id')::uuid; END IF;
 IF EXISTS(SELECT 1 FROM privacy_private.hidden_report_owners WHERE report_id=target) THEN
  INSERT INTO privacy_private.hidden_report_artifacts VALUES((item->>'id')::uuid,target) ON CONFLICT DO NOTHING;
  strike:=nullif(item->>'strike_id','')::uuid;
  IF strike IS NOT NULL THEN INSERT INTO privacy_private.hidden_report_artifacts VALUES(strike,target) ON CONFLICT DO NOTHING; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION privacy_private.capture_hidden_queue_reference() FROM PUBLIC,anon,authenticated;
DO $$ BEGIN IF to_regclass('public.manual_review_queue') IS NOT NULL THEN
 CREATE TRIGGER capture_hidden_queue_insert AFTER INSERT ON public.manual_review_queue FOR EACH ROW EXECUTE FUNCTION privacy_private.capture_hidden_queue_reference();
 CREATE TRIGGER capture_hidden_queue_change BEFORE UPDATE OR DELETE ON public.manual_review_queue FOR EACH ROW EXECUTE FUNCTION privacy_private.capture_hidden_queue_reference();
END IF; END $$;

DO $$ BEGIN
 IF to_regclass('public.strikes') IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='strikes' AND column_name='report_id') THEN
   CREATE VIEW public.staff_visible_strikes WITH (security_barrier=true,security_invoker=false) AS
    SELECT s.* FROM public.strikes s WHERE NOT EXISTS(
     SELECT 1 FROM privacy_private.hidden_report_owners h WHERE h.report_id=s.report_id);
  ELSE
   CREATE VIEW public.staff_visible_strikes WITH (security_barrier=true,security_invoker=false) AS
    SELECT s.* FROM public.strikes s WHERE NOT EXISTS(SELECT 1 FROM privacy_private.hidden_report_artifacts x WHERE x.record_id=s.id) AND NOT EXISTS(
     SELECT 1 FROM public.manual_review_queue q JOIN privacy_private.hidden_report_owners h ON h.report_id=coalesce(q.report_id,(SELECT x.report_id FROM privacy_private.hidden_report_artifacts x WHERE x.record_id=q.id)) WHERE q.strike_id=s.id);
  END IF;
  REVOKE ALL ON public.staff_visible_strikes FROM PUBLIC,anon,authenticated;
  GRANT SELECT ON public.staff_visible_strikes TO service_role;
 END IF;
END $$;

-- Service-only metadata for all HTTP serializers, including stored conflict/replay payloads.
CREATE FUNCTION public.read_report_identity_context(report_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF report_ids IS NULL OR cardinality(report_ids)>1000 THEN RAISE EXCEPTION 'Invalid report context batch' USING ERRCODE='22023'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'user_id',coalesce(h.owner_id,r.user_id),
  'hide_identity',h.report_id IS NOT NULL OR coalesce(r.hide_identity,false))),'[]'::jsonb) INTO result
 FROM (SELECT DISTINCT unnest(report_ids) AS id) i LEFT JOIN public.reports r ON r.id=i.id
 LEFT JOIN privacy_private.hidden_report_artifacts a ON a.record_id=i.id
 LEFT JOIN privacy_private.hidden_report_owners h ON h.report_id=coalesce(a.report_id,i.id) WHERE r.id IS NOT NULL OR h.report_id IS NOT NULL;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.read_report_identity_context(uuid[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_report_identity_context(uuid[]) TO service_role;

-- Retire unreviewed legacy projections, including transitive wrappers and column grants.
-- The two public/operational contracts are explicitly preserved; backend-only views remain usable.
DO $$ DECLARE v record; cols text; BEGIN
 FOR v IN WITH RECURSIVE dependencies(oid) AS (
  SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN
    ('reports','audit_logs','strikes','manual_review_queue','fc_operation_log','fc_conflict_audit','sweeper_audit_log')
  UNION SELECT rw.ev_class FROM dependencies base JOIN pg_depend d ON d.refobjid=base.oid
   JOIN pg_rewrite rw ON rw.oid=d.objid WHERE rw.ev_class<>base.oid
 ) SELECT c.oid,c.relname FROM dependencies d JOIN pg_class c ON c.oid=d.oid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind='v' AND n.nspname='public' AND c.relname NOT IN ('public_reports','reports_view','response_log','report_activity_view') LOOP
  SELECT string_agg(quote_ident(attname),',') INTO cols FROM pg_attribute WHERE attrelid=v.oid AND attnum>0 AND NOT attisdropped;
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',v.relname);
  EXECUTE format('REVOKE SELECT (%s), INSERT (%s), UPDATE (%s), REFERENCES (%s) ON public.%I FROM PUBLIC,anon,authenticated',cols,cols,cols,cols,v.relname);
  EXECUTE format('GRANT SELECT ON public.%I TO service_role',v.relname);
 END LOOP;
 IF to_regclass('public.response_log') IS NOT NULL THEN
  ALTER VIEW public.response_log SET (security_invoker=true,security_barrier=true);
 END IF;
END $$;

-- Client-callable definer JSON/record RPCs must not bypass the raw-row privacy boundary.
-- Operational mutations continue through the authenticated backend using service_role.
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prosecdef AND p.prorettype IN ('json'::regtype,'jsonb'::regtype,'record'::regtype,'public.reports'::regtype)
 AND p.prosrc ~* '(reports|audit_logs|fc_operation_log|fc_conflict_audit)' LOOP
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.signature);
 END LOOP;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
