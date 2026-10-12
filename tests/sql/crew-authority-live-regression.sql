-- Live rollback-only regression: no Auth table writes, accounts, email or persisted role changes.
-- Synthetic tasks, teams, reports and temporary profile role are rolled back.
BEGIN;
SET LOCAL statement_timeout='20s';
SET LOCAL lock_timeout='2s';

CREATE TEMP TABLE crew_authority_results(test text,status text) ON COMMIT DROP;
GRANT INSERT,SELECT ON crew_authority_results TO authenticated,service_role;
CREATE FUNCTION pg_temp.crew_authority_assert(label text,condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO crew_authority_results VALUES(label,CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END);
END $$;

DO $$
DECLARE
  explicit_person uuid:=gen_random_uuid(); excluded_member uuid:=gen_random_uuid();
  citizen uuid:=gen_random_uuid(); team uuid:=gen_random_uuid();
  subset_task uuid:=gen_random_uuid(); other_task uuid:=gen_random_uuid();
  canonical_report uuid:=gen_random_uuid(); stale_report uuid:=gen_random_uuid();
  projection jsonb; executable boolean; visible_count integer; generation bigint;
BEGIN
  -- Existing identities only; temporary profile role is transaction-local and rolled back.
  SELECT id INTO explicit_person FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
  SELECT id INTO excluded_member FROM public.profiles WHERE role::text='citizen' LIMIT 1;
  SELECT id INTO citizen FROM public.profiles WHERE role::text='citizen' AND id<>excluded_member LIMIT 1;
  IF explicit_person IS NULL OR excluded_member IS NULL OR citizen IS NULL THEN RAISE EXCEPTION 'Insufficient existing fixture identities'; END IF;
  UPDATE public.profiles SET role='field_crew' WHERE id=excluded_member;
  INSERT INTO public.field_crews(id,name,team_lead_profile_id,member_profile_ids)
  VALUES(team,'Synthetic subset team',explicit_person,ARRAY[explicit_person,excluded_member]);
  INSERT INTO public.cleanup_tasks(id,title,description,assigned_field_crew_id,assigned_crew_ids,route_status,status,report_ids)
  VALUES
    (subset_task,'Synthetic explicit-subset task','Private operational detail',team,ARRAY[explicit_person],'ready','pending','{}'::uuid[]),
    (other_task,'Synthetic other canonical task','Separate task detail',NULL,ARRAY[explicit_person],'ready','pending','{}'::uuid[]);
  INSERT INTO public.reports(id,user_id,title,issue_type,location,validation_status,cleanup_task_id,on_private_property,property_owner_consent_status)
  VALUES
    (canonical_report,citizen,'Synthetic canonical report','waste',extensions.st_setsrid(extensions.st_makepoint(121,14.5),4326),'approved',subset_task,true,'denied'),
    (stale_report,citizen,'Synthetic other-task report','waste',extensions.st_setsrid(extensions.st_makepoint(121.01,14.51),4326),'approved',other_task,true,'denied');

  -- Team membership is descriptive; the nonempty person subset is explicit authority.
  SET LOCAL ROLE service_role;
  projection:=public.read_authorized_cleanup_tasks(explicit_person,subset_task);
  PERFORM pg_temp.crew_authority_assert('Explicit assignee retains operational detail',
    jsonb_array_length(projection)=1 AND projection->0->>'access_level'='detail');
  projection:=public.read_authorized_cleanup_tasks(excluded_member,subset_task);
  PERFORM pg_temp.crew_authority_assert('Excluded teammate receives no operational detail',
    NOT EXISTS(SELECT FROM jsonb_array_elements(projection) item WHERE item->>'access_level'='detail'));
  projection:=public.read_authorized_cleanup_tasks(excluded_member,subset_task,NULL,true);
  PERFORM pg_temp.crew_authority_assert('Assigned-only listing excludes unassigned teammate',projection='[]'::jsonb);
  projection:=public.read_authorized_cleanup_tasks(explicit_person,subset_task,NULL,true);
  PERFORM pg_temp.crew_authority_assert('Assigned-only listing retains explicit assignee',
    jsonb_array_length(projection)=1 AND projection->0->>'access_level'='detail');
  SELECT workflow_private.can_execute_task(excluded_member,t) INTO executable
    FROM public.cleanup_tasks t WHERE t.id=subset_task;
  PERFORM pg_temp.crew_authority_assert('Excluded teammate cannot execute task',executable IS FALSE);
  SELECT workflow_private.can_execute_task(explicit_person,t) INTO executable
    FROM public.cleanup_tasks t WHERE t.id=subset_task;
  PERFORM pg_temp.crew_authority_assert('Explicit assignee can execute ready active task',executable IS TRUE);
  RESET ROLE;

  -- These are actual authenticated RLS reads, not owner queries with a manual filter.
  PERFORM set_config('request.jwt.claim.sub',excluded_member::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',excluded_member,'role','authenticated')::text,true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.cleanup_tasks WHERE id=subset_task;
  PERFORM pg_temp.crew_authority_assert('Authenticated excluded teammate cannot read base task row',visible_count=0);
  RESET ROLE;
  PERFORM set_config('request.jwt.claim.sub',explicit_person::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',explicit_person,'role','authenticated')::text,true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.cleanup_tasks WHERE id=subset_task;
  PERFORM pg_temp.crew_authority_assert('Authenticated explicit assignee can read base task row',visible_count=1);
  RESET ROLE;

  -- The array is stale: one entry belongs canonically to another live task.
  -- Changing route_revision forces a fresh assignment generation and receipt issuance.
  UPDATE public.cleanup_tasks SET report_ids=ARRAY[canonical_report,stale_report],route_revision=route_revision+1
    WHERE id=subset_task RETURNING assignment_generation INTO generation;
  SET LOCAL ROLE service_role;
  PERFORM pg_temp.crew_authority_assert('Canonical report receives fresh explicit-person receipt',
    EXISTS(SELECT FROM public.field_assignment_receipts
      WHERE task_id=subset_task AND report_id=canonical_report AND crew_id=explicit_person
        AND assignment_generation=generation));
  PERFORM pg_temp.crew_authority_assert('Stale array cannot mint receipt for another tasks report',
    NOT EXISTS(SELECT FROM public.field_assignment_receipts
      WHERE task_id=subset_task AND report_id=stale_report));
  PERFORM pg_temp.crew_authority_assert('Excluded teammate has no assignment receipts',
    NOT EXISTS(SELECT FROM public.field_assignment_receipts WHERE task_id=subset_task AND crew_id=excluded_member));
  PERFORM pg_temp.crew_authority_assert('Other report retains its canonical task claim',
    (SELECT cleanup_task_id=other_task FROM public.reports WHERE id=stale_report));
  RESET ROLE;
END $$;

SELECT test,status FROM crew_authority_results ORDER BY test;
ROLLBACK;
