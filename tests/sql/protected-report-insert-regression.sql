BEGIN;
SET LOCAL statement_timeout='20s';
SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE protected_insert_results(test text,status text,detail text) ON COMMIT DROP;
GRANT INSERT,SELECT ON protected_insert_results TO authenticated;
DO $$
DECLARE actor uuid; item record; observed text;
BEGIN
SELECT id INTO actor FROM public.profiles WHERE role::text='citizen' LIMIT 1;
IF actor IS NULL THEN RAISE EXCEPTION 'Citizen fixture prerequisite missing'; END IF;
PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',actor::text,'role','authenticated','user_metadata',jsonb_build_object('role','admin'))::text,true);
PERFORM set_config('request.jwt.claim.sub',actor::text,true);
PERFORM set_config('role','authenticated',true);
FOR item IN SELECT * FROM (VALUES
('validation_status','''approved'''),
('status','''resolved'''),
('stage','''resolved'''),
('hazard_class','''non_hazardous'''),
('report_claim_generation','99'),
('fc_version','99'),
('cleanup_task_id','gen_random_uuid()'),
('severity_score','99'),
('ai_score','99'),
('before_photo_url','''https://synthetic.invalid/private'''),
('notes','''spoofed internal note'''),
('deadline_at','now()'),
('lifecycle_state','''closed''')
) AS fields(column_name,value_sql)
LOOP
BEGIN
EXECUTE format('INSERT INTO public.reports(user_id,title,issue_type,location,%I) VALUES($1,''Protected insert rollback fixture'',''waste'',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),%s)',item.column_name,item.value_sql) USING actor;
INSERT INTO protected_insert_results VALUES(item.column_name,'FAIL','Protected field accepted');
EXCEPTION WHEN OTHERS THEN
GET STACKED DIAGNOSTICS observed=RETURNED_SQLSTATE;
INSERT INTO protected_insert_results VALUES(item.column_name,CASE WHEN observed='42501' THEN 'PASS' ELSE 'FAIL' END,observed);
END;
END LOOP;
BEGIN
INSERT INTO public.reports(user_id,title,issue_type,location) VALUES(actor,'Allowed citizen insert rollback fixture','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326));
INSERT INTO protected_insert_results VALUES('Allowed citizen report submission','PASS','Inserted within rollback-only transaction');
EXCEPTION WHEN OTHERS THEN
GET STACKED DIAGNOSTICS observed=RETURNED_SQLSTATE;
INSERT INTO protected_insert_results VALUES('Allowed citizen report submission','FAIL',observed);
END;
PERFORM set_config('role','postgres',true);
END $$;
SELECT * FROM protected_insert_results ORDER BY test;
ROLLBACK;
