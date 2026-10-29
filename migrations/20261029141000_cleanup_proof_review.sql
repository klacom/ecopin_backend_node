BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.cleanup_proof_publications (
 report_id uuid PRIMARY KEY REFERENCES public.reports(id) ON DELETE CASCADE,
 id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
 source_fingerprint text NOT NULL,
 before_path text NOT NULL,
 after_path text NOT NULL,
 public_notes text NOT NULL CHECK(length(btrim(public_notes)) BETWEEN 1 AND 2000),
 redactions jsonb NOT NULL,
 completed_at timestamptz NOT NULL,
 verified_at timestamptz NOT NULL DEFAULT now(),
 verified_by uuid NOT NULL REFERENCES public.profiles(id)
);
ALTER TABLE public.cleanup_proof_publications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cleanup_proof_publications FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.cleanup_proof_publications TO service_role;
CREATE FUNCTION workflow_private.cleanup_proof_fingerprint(r public.reports) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT md5(jsonb_build_array(r.before_photo_url,r.after_photo_url,r.before_photo_hash,r.after_photo_hash,r.before_photos,r.after_photos,extract(epoch from r.lgu_resolved_at),r.cleanup_action_notes)::text);
$$;
CREATE FUNCTION public.publish_cleanup_proof(report_id uuid,actor uuid,expected_version bigint,expected_fingerprint text,
 before_path text,after_path text,public_notes text,expected_publication_id uuid,redactions jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.reports; t public.cleanup_tasks; role_name text; proof public.cleanup_proof_publications;
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
 SELECT * INTO proof FROM public.cleanup_proof_publications p WHERE p.report_id=publish_cleanup_proof.report_id;
 IF proof.id IS DISTINCT FROM expected_publication_id THEN
  RAISE EXCEPTION 'Proof changed; reload before reviewing' USING ERRCODE='40001';
 END IF;
 PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(r));
 IF r.status::text NOT IN ('resolved','completed','closed','waiting_for_feedback') OR r.lgu_resolved_at IS NULL THEN
  RAISE EXCEPTION 'Cleanup must have a recorded completion time before verification' USING ERRCODE='22023';
 END IF;
 IF nullif(btrim(public_notes),'') IS NULL OR length(public_notes)>2000 OR
  before_path !~ ('^'||report_id::text||'/before/[a-f0-9-]+[.]jpg$') OR
  after_path !~ ('^'||report_id::text||'/after/[a-f0-9-]+[.]jpg$') THEN
  RAISE EXCEPTION 'Redacted proof and public action notes are required' USING ERRCODE='22023';
 END IF;
 INSERT INTO public.cleanup_proof_publications(report_id,source_fingerprint,before_path,after_path,public_notes,redactions,completed_at,verified_by)
 VALUES(report_id,expected_fingerprint,before_path,after_path,btrim(public_notes),redactions,r.lgu_resolved_at,actor)
 ON CONFLICT ON CONSTRAINT cleanup_proof_publications_pkey DO UPDATE SET id=gen_random_uuid(),source_fingerprint=excluded.source_fingerprint,
  before_path=excluded.before_path,after_path=excluded.after_path,public_notes=excluded.public_notes,
  redactions=excluded.redactions,completed_at=excluded.completed_at,verified_at=now(),verified_by=actor RETURNING * INTO proof;
 RETURN to_jsonb(proof);
END; $$;
CREATE FUNCTION public.read_cleanup_proof(report_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('id',p.id,'public_notes',p.public_notes,'completed_at',p.completed_at,'verified_at',p.verified_at,
  'before_path',p.before_path,'after_path',p.after_path)
 FROM public.cleanup_proof_publications p JOIN public.public_reports visible ON visible.id=p.report_id
 JOIN public.reports r ON r.id=p.report_id
 WHERE p.report_id=read_cleanup_proof.report_id AND p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r)
 AND r.status::text IN ('resolved','completed','closed','waiting_for_feedback');
$$;
CREATE FUNCTION public.read_cleanup_proof_source(report_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('report_id',r.id,'version',r.fc_version,'fingerprint',workflow_private.cleanup_proof_fingerprint(r),
  'before_url',r.before_photo_url,'after_url',r.after_photo_url,'completed_at',r.lgu_resolved_at,
  'action_notes',coalesce(nullif(btrim(r.cleanup_action_notes),''),(SELECT o.notes FROM public.task_report_outcomes o WHERE o.report_id=r.id AND o.outcome='cleaned' AND o.disposition='applied' ORDER BY o.submitted_at DESC LIMIT 1)),
  'publication_id',p.id,
  'existing_public_notes',CASE WHEN p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) THEN p.public_notes END,
  'existing_redactions',CASE WHEN p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) THEN p.redactions END)
 FROM public.reports r LEFT JOIN public.cleanup_proof_publications p ON p.report_id=r.id WHERE r.id=read_cleanup_proof_source.report_id;
$$;
REVOKE ALL ON FUNCTION workflow_private.cleanup_proof_fingerprint(public.reports),
 public.publish_cleanup_proof(uuid,uuid,bigint,text,text,text,text,uuid,jsonb),public.read_cleanup_proof(uuid),public.read_cleanup_proof_source(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.cleanup_proof_fingerprint(public.reports),
 public.publish_cleanup_proof(uuid,uuid,bigint,text,text,text,text,uuid,jsonb),public.read_cleanup_proof(uuid),public.read_cleanup_proof_source(uuid) TO service_role;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES
 ('Cleanup Originals','Cleanup Originals',false,10485760,ARRAY['image/jpeg','image/png','image/webp']),
 ('Cleanup Proof','Cleanup Proof',false,10485760,ARRAY['image/jpeg']) ON CONFLICT(id) DO UPDATE
 SET public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
-- Retain receipt validation while accepting the private references produced by the upload API.
DO $$ DECLARE source text;
BEGIN
 SELECT pg_get_functiondef('public.reconcile_report_outcome(uuid,text,jsonb)'::regprocedure) INTO source;
 IF position('where e.ref !~ ''^https://[^[:space:]]+$''' IN source)=0 THEN RAISE EXCEPTION 'Unexpected receipt function; review migration'; END IF;
 source:=replace(source,'where e.ref !~ ''^https://[^[:space:]]+$''',
  'where e.ref !~ ''^https://[^[:space:]]+$'' AND e.ref !~ ''^storage://Cleanup%20Originals/[a-f0-9-]+/after/[a-f0-9-]+[.](jpg|png|webp)$''');
 EXECUTE source;
END; $$;
NOTIFY pgrst,'reload schema';
COMMIT;
