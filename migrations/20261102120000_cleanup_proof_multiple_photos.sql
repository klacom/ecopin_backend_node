-- Several reviewed Before/After photos per report (crew may add up to 5 per slot).
-- Additive: before_path/after_path keep the first reviewed photo, so existing publications and older clients keep working.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF position('''before_url'',r.before_photo_url' IN pg_get_functiondef('public.read_cleanup_proof_source(uuid)'::regprocedure))=0 OR
    position('''before_path'',p.before_path' IN pg_get_functiondef('public.read_cleanup_proof(uuid)'::regprocedure))=0 THEN
  RAISE EXCEPTION 'Unexpected cleanup proof functions; review migration';
 END IF;
END; $$;

ALTER TABLE public.cleanup_proof_publications
 ADD COLUMN before_paths jsonb CHECK(before_paths IS NULL OR (jsonb_typeof(before_paths)='array' AND jsonb_array_length(before_paths) BETWEEN 1 AND 5)),
 ADD COLUMN after_paths jsonb CHECK(after_paths IS NULL OR (jsonb_typeof(after_paths)='array' AND jsonb_array_length(after_paths) BETWEEN 1 AND 5)),
 ADD CONSTRAINT cleanup_proof_first_paths_match CHECK(
  (before_paths IS NULL OR before_paths->>0=before_path) AND (after_paths IS NULL OR after_paths->>0=after_path));

-- Ordered source photo references for one slot. Falls back to the single legacy column when the collection is empty.
CREATE FUNCTION workflow_private.cleanup_proof_photo_urls(r public.reports,slot text) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE
  WHEN jsonb_array_length(s.photos)>0 THEN coalesce((SELECT jsonb_agg(e.p->>'url' ORDER BY e.ord) FROM jsonb_array_elements(s.photos) WITH ORDINALITY e(p,ord)
   WHERE e.ord<=5 AND nullif(btrim(e.p->>'url'),'') IS NOT NULL),'[]'::jsonb)
  WHEN nullif(btrim(s.single),'') IS NOT NULL THEN jsonb_build_array(s.single)
  ELSE '[]'::jsonb END
 FROM (SELECT CASE WHEN slot='before' THEN r.before_photos ELSE r.after_photos END AS photos,
              CASE WHEN slot='before' THEN r.before_photo_url ELSE r.after_photo_url END AS single) s;
$$;

CREATE FUNCTION public.publish_cleanup_proof_photos(report_id uuid,actor uuid,expected_version bigint,expected_fingerprint text,
 before_paths jsonb,after_paths jsonb,public_notes text,expected_publication_id uuid,redactions jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.reports; t public.cleanup_tasks; role_name text; proof public.cleanup_proof_publications; slot_name text; slot_paths jsonb;
BEGIN
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor;
 IF role_name IS NULL OR role_name NOT IN ('admin','officer') THEN RAISE EXCEPTION 'Officer review required' USING ERRCODE='42501'; END IF;
 SELECT * INTO r FROM public.reports WHERE id=report_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report not found' USING ERRCODE='P0002'; END IF;
 IF r.cleanup_task_id IS NOT NULL THEN
  SELECT * INTO t FROM public.cleanup_tasks WHERE id=r.cleanup_task_id;
  IF role_name<>'admin' AND coalesce(t.created_by,t.lgu_user_id) IS NOT NULL AND
    actor IS DISTINCT FROM t.created_by AND actor IS DISTINCT FROM t.lgu_user_id THEN
   RAISE EXCEPTION 'Report belongs to another officer' USING ERRCODE='42501';
  END IF;
 END IF;
 IF r.fc_version IS DISTINCT FROM expected_version OR workflow_private.cleanup_proof_fingerprint(r) IS DISTINCT FROM expected_fingerprint THEN
  RAISE EXCEPTION 'Proof changed; reload before reviewing' USING ERRCODE='40001';
 END IF;
 SELECT * INTO proof FROM public.cleanup_proof_publications p WHERE p.report_id=publish_cleanup_proof_photos.report_id;
 IF proof.id IS DISTINCT FROM expected_publication_id THEN
  RAISE EXCEPTION 'Proof changed; reload before reviewing' USING ERRCODE='40001';
 END IF;
 PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(r));
 IF r.status::text NOT IN ('resolved','completed','closed','waiting_for_feedback') OR r.lgu_resolved_at IS NULL THEN
  RAISE EXCEPTION 'Cleanup must have a recorded completion time before verification' USING ERRCODE='22023';
 END IF;
 IF nullif(btrim(public_notes),'') IS NULL OR length(public_notes)>2000 THEN
  RAISE EXCEPTION 'Redacted proof and public action notes are required' USING ERRCODE='22023';
 END IF;
 -- Every source photo needs exactly one reviewed copy, in the same order, stored under this report and slot.
 FOREACH slot_name IN ARRAY ARRAY['before','after'] LOOP
  slot_paths:=CASE WHEN slot_name='before' THEN before_paths ELSE after_paths END;
  IF jsonb_typeof(slot_paths) IS DISTINCT FROM 'array' OR
     jsonb_array_length(slot_paths)<>jsonb_array_length(workflow_private.cleanup_proof_photo_urls(r,slot_name)) OR
     jsonb_array_length(slot_paths)=0 OR jsonb_array_length(slot_paths)>5 OR
     EXISTS(SELECT 1 FROM jsonb_array_elements(slot_paths) e WHERE jsonb_typeof(e)<>'string' OR
      (e#>>'{}') !~ ('^'||report_id::text||'/'||slot_name||'/[a-f0-9-]+[.]jpg$')) OR
     (SELECT count(DISTINCT e#>>'{}') FROM jsonb_array_elements(slot_paths) e)<>jsonb_array_length(slot_paths) THEN
   RAISE EXCEPTION 'A redacted copy of every % photo is required',slot_name USING ERRCODE='22023';
  END IF;
 END LOOP;
 INSERT INTO public.cleanup_proof_publications(report_id,source_fingerprint,before_path,after_path,before_paths,after_paths,public_notes,redactions,completed_at,verified_by)
 VALUES(report_id,expected_fingerprint,before_paths->>0,after_paths->>0,before_paths,after_paths,btrim(public_notes),redactions,r.lgu_resolved_at,actor)
 ON CONFLICT ON CONSTRAINT cleanup_proof_publications_pkey DO UPDATE SET id=gen_random_uuid(),source_fingerprint=excluded.source_fingerprint,
  before_path=excluded.before_path,after_path=excluded.after_path,before_paths=excluded.before_paths,after_paths=excluded.after_paths,
  public_notes=excluded.public_notes,redactions=excluded.redactions,completed_at=excluded.completed_at,verified_at=now(),verified_by=actor RETURNING * INTO proof;
 RETURN to_jsonb(proof);
END; $$;

-- The original single-photo signature stays callable for a backend that has not been upgraded yet.
-- It is rejected for reports with several photos because one reviewed copy cannot cover them.
CREATE OR REPLACE FUNCTION public.publish_cleanup_proof(report_id uuid,actor uuid,expected_version bigint,expected_fingerprint text,
 before_path text,after_path text,public_notes text,expected_publication_id uuid,redactions jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT public.publish_cleanup_proof_photos(report_id,actor,expected_version,expected_fingerprint,
  jsonb_build_array(before_path),jsonb_build_array(after_path),public_notes,expected_publication_id,redactions);
$$;

CREATE OR REPLACE FUNCTION public.read_cleanup_proof(report_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('id',p.id,'public_notes',p.public_notes,'completed_at',p.completed_at,'verified_at',p.verified_at,
  'before_path',p.before_path,'after_path',p.after_path,
  'before_paths',coalesce(p.before_paths,jsonb_build_array(p.before_path)),'after_paths',coalesce(p.after_paths,jsonb_build_array(p.after_path)))
 FROM public.cleanup_proof_publications p JOIN public.public_reports visible ON visible.id=p.report_id
 JOIN public.reports r ON r.id=p.report_id
 WHERE p.report_id=read_cleanup_proof.report_id AND p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r)
 AND r.status::text IN ('resolved','completed','closed','waiting_for_feedback');
$$;

CREATE OR REPLACE FUNCTION public.read_cleanup_proof_source(report_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('report_id',r.id,'version',r.fc_version,'fingerprint',workflow_private.cleanup_proof_fingerprint(r),
  'before_url',r.before_photo_url,'after_url',r.after_photo_url,
  'before_urls',workflow_private.cleanup_proof_photo_urls(r,'before'),'after_urls',workflow_private.cleanup_proof_photo_urls(r,'after'),
  'completed_at',r.lgu_resolved_at,
  'action_notes',coalesce(nullif(btrim(r.cleanup_action_notes),''),(SELECT o.notes FROM public.task_report_outcomes o WHERE o.report_id=r.id AND o.outcome='cleaned' AND o.disposition='applied' ORDER BY o.submitted_at DESC LIMIT 1)),
  'publication_id',p.id,
  'existing_public_notes',CASE WHEN p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) THEN p.public_notes END,
  'existing_redactions',CASE WHEN p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) THEN p.redactions END)
 FROM public.reports r LEFT JOIN public.cleanup_proof_publications p ON p.report_id=r.id WHERE r.id=read_cleanup_proof_source.report_id;
$$;

REVOKE ALL ON FUNCTION workflow_private.cleanup_proof_photo_urls(public.reports,text),
 public.publish_cleanup_proof_photos(uuid,uuid,bigint,text,jsonb,jsonb,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.cleanup_proof_photo_urls(public.reports,text),
 public.publish_cleanup_proof_photos(uuid,uuid,bigint,text,jsonb,jsonb,text,uuid,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.publish_cleanup_proof(uuid,uuid,bigint,text,text,text,text,uuid,jsonb),public.read_cleanup_proof(uuid),public.read_cleanup_proof_source(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.publish_cleanup_proof(uuid,uuid,bigint,text,text,text,text,uuid,jsonb),public.read_cleanup_proof(uuid),public.read_cleanup_proof_source(uuid) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
