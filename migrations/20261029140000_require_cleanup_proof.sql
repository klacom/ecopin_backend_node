BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.reports ADD COLUMN cleanup_action_notes text;
REVOKE SELECT(cleanup_action_notes),UPDATE(cleanup_action_notes) ON public.reports FROM anon,authenticated;
-- A table-wide grant overrides a column revoke. Preserve existing columns, not the new private field.
DO $$ DECLARE columns_list text; role_name text; privilege_name text;
BEGIN
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO columns_list FROM pg_attribute
 WHERE attrelid='public.reports'::regclass AND attnum>0 AND NOT attisdropped AND attname<>'cleanup_action_notes';
 FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
  FOREACH privilege_name IN ARRAY ARRAY['SELECT','UPDATE'] LOOP
   IF has_table_privilege(role_name,'public.reports',privilege_name) THEN
    EXECUTE format('REVOKE %s ON public.reports FROM %I',privilege_name,role_name);
    EXECUTE format('GRANT %s (%s) ON public.reports TO %I',privilege_name,columns_list,role_name);
   END IF;
  END LOOP;
 END LOOP;
END; $$;
ALTER TABLE public.task_report_outcomes ADD COLUMN evidence_verification text NOT NULL DEFAULT 'unverified'
 CHECK(evidence_verification IN ('verified','unverified'));
CREATE FUNCTION workflow_private.assert_cleanup_photo_pair(r jsonb) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
BEGIN
 IF coalesce(r->>'issue_type','') IN ('scouting','acknowledge_only') THEN RETURN; END IF;
 IF nullif(btrim(r->>'before_photo_url'),'') IS NULL OR nullif(btrim(r->>'after_photo_url'),'') IS NULL THEN
  RAISE EXCEPTION 'Before and After photos are required for physical cleanup' USING ERRCODE='22023';
 END IF;
 IF r->>'before_photo_url'=r->>'after_photo_url' OR
  (nullif(r->>'before_photo_hash','') IS NOT NULL AND r->>'before_photo_hash'=r->>'after_photo_hash') THEN
  RAISE EXCEPTION 'Before and After must be different photos' USING ERRCODE='22023';
 END IF;
END; $$;

CREATE FUNCTION workflow_private.guard_cleanup_resolution() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.status::text IN ('resolved','completed','waiting_for_feedback') AND
    OLD.status::text NOT IN ('resolved','completed','closed','waiting_for_feedback') THEN
  PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(NEW));
  IF coalesce(NEW.issue_type::text,'') NOT IN ('scouting','acknowledge_only') AND
    (nullif(btrim(NEW.cleanup_action_notes),'') IS NULL OR length(NEW.cleanup_action_notes)>2000) THEN
   RAISE EXCEPTION 'Action notes are required (maximum 2000 characters)' USING ERRCODE='22023';
  END IF;
  NEW.lgu_resolved_at:=now();
 ELSIF OLD.status::text IN ('resolved','completed','closed','waiting_for_feedback') AND
   (NEW.before_photo_url IS NULL AND OLD.before_photo_url IS NOT NULL OR
    NEW.after_photo_url IS NULL AND OLD.after_photo_url IS NOT NULL OR
    jsonb_array_length(NEW.before_photos)<jsonb_array_length(OLD.before_photos) OR
    jsonb_array_length(NEW.after_photos)<jsonb_array_length(OLD.after_photos)) THEN
  RAISE EXCEPTION 'Completed cleanup photos cannot be deleted' USING ERRCODE='22023';
 END IF;
 IF OLD.status::text IN ('resolved','completed','closed','waiting_for_feedback') AND
   NEW.status::text IN ('resolved','completed','closed','waiting_for_feedback') THEN
  NEW.lgu_resolved_at:=OLD.lgu_resolved_at;
  IF OLD.before_photo_url IS NOT NULL AND OLD.after_photo_url IS NOT NULL THEN
   PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(NEW));
  END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER require_cleanup_resolution_proof BEFORE UPDATE OF status,lgu_resolved_at,cleanup_action_notes,before_photo_url,after_photo_url,before_photo_hash,after_photo_hash,before_photos,after_photos ON public.reports
 FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cleanup_resolution();

CREATE FUNCTION workflow_private.guard_cleanup_receipt() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE r public.reports; matches_current boolean;
BEGIN
 IF NEW.outcome NOT IN ('cleaned','already_resolved') THEN RETURN NEW; END IF;
 SELECT * INTO r FROM public.reports WHERE id=NEW.report_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report no longer exists'; END IF;
 IF nullif(btrim(NEW.notes),'') IS NULL OR length(NEW.notes)>2000 THEN
  RAISE EXCEPTION 'Action notes are required (maximum 2000 characters)' USING ERRCODE='22023';
 END IF;
 matches_current:=jsonb_array_length(NEW.evidence_refs)>0 AND NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements_text(NEW.evidence_refs) e(ref)
    WHERE nullif(btrim(ref),'') IS NULL OR NOT (
      ref=coalesce(r.after_photo_url,'') OR EXISTS(
       SELECT 1 FROM jsonb_array_elements(coalesce(r.after_photos,'[]')) p WHERE p->>'url'=ref)));
 NEW.evidence_verification:=CASE WHEN matches_current THEN 'verified' ELSE 'unverified' END;
 -- Historical claims remain reviewable, but cannot become accepted cleanup proof.
 IF NEW.disposition IN ('contested','verification_required') THEN RETURN NEW; END IF;
 IF NEW.outcome='cleaned' THEN PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(r)); END IF;
 IF coalesce(r.issue_type::text,'') NOT IN ('scouting','acknowledge_only') AND NOT matches_current THEN
  RAISE EXCEPTION 'Outcome evidence must reference this report''s uploaded After photos' USING ERRCODE='22023';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER require_cleanup_receipt_proof BEFORE INSERT ON public.task_report_outcomes
 FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cleanup_receipt();

CREATE FUNCTION workflow_private.guard_cleanup_task_completion() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE r public.reports; linked boolean:=false;
BEGIN
 IF NEW.status::text<>'completed' OR OLD.status::text='completed' OR
  NOT (NEW.completion_result='cleanup_completed' OR
       (NEW.completion_result='completed' AND NEW.task_type::text IN ('Cleanup','Sweeper'))) THEN RETURN NEW; END IF;
 FOR r IN SELECT * FROM public.reports WHERE cleanup_task_id=NEW.id AND status::text<>'rejected' ORDER BY id FOR UPDATE LOOP
  linked:=true;
  IF NOT EXISTS(SELECT 1 FROM public.task_report_outcomes o WHERE o.report_id=r.id AND o.task_id=NEW.id
   AND o.outcome='already_resolved' AND o.disposition='acknowledged_already_resolved' AND o.evidence_verification='verified') THEN
   PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(r));
  END IF;
  IF nullif(btrim(NEW.completion_notes),'') IS NULL AND NOT EXISTS(
   SELECT 1 FROM public.task_report_outcomes o WHERE o.report_id=r.id AND o.task_id=NEW.id
    AND o.outcome IN ('cleaned','already_resolved') AND o.disposition IN ('applied','acknowledged_already_resolved')
    AND o.evidence_verification='verified' AND nullif(btrim(o.notes),'') IS NOT NULL) THEN
   RAISE EXCEPTION 'Action notes are required for each cleanup report' USING ERRCODE='22023';
  END IF;
 END LOOP;
 IF NOT linked THEN
  PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(NEW));
  IF nullif(btrim(NEW.completion_notes),'') IS NULL THEN
   RAISE EXCEPTION 'Action notes are required for cleanup completion' USING ERRCODE='22023';
  END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER require_cleanup_task_proof BEFORE UPDATE OF status ON public.cleanup_tasks
 FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cleanup_task_completion();
REVOKE ALL ON FUNCTION workflow_private.assert_cleanup_photo_pair(jsonb),workflow_private.guard_cleanup_resolution(),
 workflow_private.guard_cleanup_receipt(),workflow_private.guard_cleanup_task_completion() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.assert_cleanup_photo_pair(jsonb),workflow_private.guard_cleanup_resolution(),
 workflow_private.guard_cleanup_receipt(),workflow_private.guard_cleanup_task_completion() TO service_role;
COMMIT;
