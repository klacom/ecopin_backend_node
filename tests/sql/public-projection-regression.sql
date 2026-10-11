BEGIN; SET LOCAL statement_timeout='15s'; SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE public_projection_audit(test text,status text,detail text) ON COMMIT DROP;
GRANT INSERT ON public_projection_audit TO anon,authenticated;
DO $$ DECLARE owner_id uuid; other_id uuid; rid uuid:=gen_random_uuid(); private_id uuid:=gen_random_uuid(); denied_id uuid:=gen_random_uuid(); pending_id uuid:=gen_random_uuid(); unapproved_id uuid:=gen_random_uuid(); rejected_id uuid:=gen_random_uuid(); missing_id uuid:=gen_random_uuid(); seen integer; row_data jsonb; target_role text; BEGIN
SELECT id INTO owner_id FROM public.profiles WHERE role::text='citizen' LIMIT 1;
SELECT id INTO other_id FROM public.profiles WHERE role::text='citizen' AND id<>owner_id LIMIT 1;
INSERT INTO public.reports(id,user_id,title,notes,issue_type,location,severity_score,validation_status,status,on_private_property,property_owner_consent_status)
VALUES(rid,owner_id,'Projection rollback fixture','Hidden internal note','waste',extensions.st_setsrid(extensions.st_makepoint(121.123456,14.123456),4326),2,'approved','unresolved',false,'not_required'),
(private_id,owner_id,'Projection rollback fixture','Hidden private note','waste',extensions.st_setsrid(extensions.st_makepoint(121.123456,14.123456),4326),2,'approved','unresolved',true,'obtained'),
(denied_id,owner_id,'Projection rollback fixture','Hidden','waste',extensions.st_setsrid(extensions.st_makepoint(121,14),4326),2,'approved','unresolved',true,'denied'),
(pending_id,owner_id,'Projection rollback fixture','Hidden','waste',extensions.st_setsrid(extensions.st_makepoint(121,14),4326),2,'approved','unresolved',true,'pending'),
(unapproved_id,owner_id,'Projection rollback fixture','Hidden','waste',extensions.st_setsrid(extensions.st_makepoint(121,14),4326),2,'pending','unresolved',false,'not_required'),
(rejected_id,owner_id,'Projection rollback fixture','Hidden','waste',extensions.st_setsrid(extensions.st_makepoint(121,14),4326),2,'approved','rejected',false,'not_required'),
(missing_id,owner_id,'Projection rollback fixture','Hidden','waste',extensions.st_setsrid(extensions.st_makepoint(121,14),4326),2,'approved','unresolved',true,'not_required');
IF to_regclass('public.public_reports') IS NULL THEN
INSERT INTO public_projection_audit VALUES('Safe public projection exists','FAIL','Missing public_reports');
RETURN;
END IF;
FOREACH target_role IN ARRAY ARRAY['anon','authenticated'] LOOP
PERFORM set_config('request.jwt.claims',jsonb_build_object('role',target_role,'sub',other_id)::text,true);
PERFORM set_config('request.jwt.claim.sub',CASE WHEN target_role='authenticated' THEN other_id::text ELSE '' END,true);
EXECUTE 'SET LOCAL ROLE '||quote_ident(target_role);
SELECT count(*) INTO seen FROM public.public_reports WHERE id=ANY(ARRAY[rid,private_id,denied_id,pending_id,unapproved_id,rejected_id,missing_id]);
INSERT INTO public_projection_audit VALUES(target_role||' sees exactly public and consented fixtures',CASE WHEN seen=2 THEN 'PASS' ELSE 'FAIL' END,'Visible='||seen);
SELECT to_jsonb(p) INTO row_data FROM public.public_reports p WHERE id=rid;
INSERT INTO public_projection_audit VALUES(target_role||' projection has no private fields',CASE WHEN row_data IS NOT NULL AND NOT(row_data ?| ARRAY['user_id','notes','idempotency_key','ml_probabilities','before_photo_url','after_photo_url','fc_version']) THEN 'PASS' ELSE 'FAIL' END,'Safe projection fields');
SELECT to_jsonb(p) INTO row_data FROM public.public_reports p WHERE id=private_id;
INSERT INTO public_projection_audit VALUES(target_role||' private location is approximate',CASE WHEN row_data->>'longitude'='121.123' AND row_data->>'latitude'='14.123' AND row_data->>'location_precision'='approximate' THEN 'PASS' ELSE 'FAIL' END,'Three decimal places');
BEGIN
EXECUTE 'SELECT notes FROM public.public_reports WHERE id=$1' USING rid;
INSERT INTO public_projection_audit VALUES(target_role||' cannot request excluded column','FAIL','Notes unexpectedly exposed');
EXCEPTION WHEN undefined_column THEN INSERT INTO public_projection_audit VALUES(target_role||' cannot request excluded column','PASS','Excluded schema field'); END;
BEGIN
UPDATE public.public_reports SET title='Unauthorized public edit' WHERE id=rid;
INSERT INTO public_projection_audit VALUES(target_role||' cannot mutate projection','FAIL','UPDATE allowed');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO public_projection_audit VALUES(target_role||' cannot mutate projection','PASS','SELECT only'); END;
RESET ROLE;
END LOOP;
INSERT INTO public_projection_audit SELECT 'Public owner cannot bypass RLS or login',CASE WHEN NOT rolbypassrls AND NOT rolsuper AND NOT rolcanlogin AND NOT rolinherit THEN 'PASS' ELSE 'FAIL' END,'Constrained view owner' FROM pg_roles WHERE rolname='ecopin_public_map_reader';
INSERT INTO public_projection_audit VALUES('Public owner cannot read private notes',CASE WHEN NOT has_column_privilege('ecopin_public_map_reader','public.reports','notes','SELECT') THEN 'PASS' ELSE 'FAIL' END,'Column restriction');
INSERT INTO public_projection_audit VALUES('Public owner cannot write base reports',CASE WHEN NOT has_table_privilege('ecopin_public_map_reader','public.reports','UPDATE') THEN 'PASS' ELSE 'FAIL' END,'Read only');
END $$;
SELECT * FROM public_projection_audit; ROLLBACK;
