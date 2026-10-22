BEGIN;
SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='15s';
CREATE TEMP TABLE batch_evidence_audit(test text, status text) ON COMMIT DROP;
DO $$
DECLARE
  owner_id uuid;
  other_id uuid;
  crew_id uuid;
  officer_id uuid;
  admin_id uuid;
  actor_id uuid;
  task_id uuid := gen_random_uuid();
  private_id uuid := gen_random_uuid();
  exact_id uuid := gen_random_uuid();
  approximate_id uuid := gen_random_uuid();
  pending_id uuid := gen_random_uuid();
  requested uuid[];
  actual uuid[];
  expected uuid[];
  sample_location public.reports.location%TYPE;
BEGIN
  SELECT id INTO owner_id FROM public.profiles WHERE role::text='citizen' LIMIT 1;
  SELECT id INTO other_id FROM public.profiles WHERE role::text='citizen' AND id<>owner_id LIMIT 1;
  SELECT id INTO crew_id FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
  SELECT id INTO officer_id FROM public.profiles WHERE role::text='officer' LIMIT 1;
  SELECT id INTO admin_id FROM public.profiles WHERE role::text='admin' LIMIT 1;
  SELECT location INTO sample_location FROM public.reports LIMIT 1;
  INSERT INTO public.cleanup_tasks(id,title,status,route_status,assigned_crew_ids)
  VALUES(task_id,'Batch evidence fixture','pending','ready',ARRAY[crew_id]);
  INSERT INTO public.reports(id,user_id,title,issue_type,location,severity_score,validation_status,
    cleanup_task_id,on_private_property,property_owner_consent_status)
  VALUES
    (private_id,owner_id,'Private','waste',sample_location,2,'approved',task_id,true,'denied'),
    (exact_id,owner_id,'Public exact','waste',sample_location,2,'approved',NULL,false,'pending'),
    (approximate_id,owner_id,'Public approximate','waste',sample_location,2,'approved',NULL,true,'obtained'),
    (pending_id,owner_id,'Unapproved','waste',sample_location,2,'pending',NULL,false,'pending');
  requested := ARRAY[private_id,exact_id,approximate_id,pending_id];

  -- Compare every decision to the existing single-report authorization path.
  FOREACH actor_id IN ARRAY ARRAY[owner_id,other_id,crew_id,officer_id,admin_id,NULL,gen_random_uuid()]
  LOOP
    SELECT array_agg(id ORDER BY id) INTO actual
    FROM public.read_authorized_report_evidence_ids(actor_id,requested);
    SELECT array_agg(id ORDER BY id) INTO expected
    FROM unnest(requested) AS input(id)
    WHERE public.read_authorized_report_detail(actor_id,id) IS NOT NULL
       OR EXISTS(SELECT 1 FROM public.public_reports p WHERE p.id=input.id AND p.location_precision='exact');
    INSERT INTO batch_evidence_audit VALUES('Matches canonical access for actor '||coalesce(actor_id::text,'NULL'),
      CASE WHEN actual IS NOT DISTINCT FROM expected THEN 'PASS' ELSE 'FAIL' END);
  END LOOP;

  UPDATE public.cleanup_tasks SET route_status='needs_replan' WHERE id=task_id;
  INSERT INTO batch_evidence_audit SELECT 'Unready crew loses private evidence',
    CASE WHEN NOT EXISTS(SELECT FROM public.read_authorized_report_evidence_ids(crew_id,ARRAY[private_id])) THEN 'PASS' ELSE 'FAIL' END;
  UPDATE public.cleanup_tasks SET route_status='ready',assigned_crew_ids='{}' WHERE id=task_id;
  INSERT INTO batch_evidence_audit SELECT 'Reassigned crew loses private evidence',
    CASE WHEN NOT EXISTS(SELECT FROM public.read_authorized_report_evidence_ids(crew_id,ARRAY[private_id])) THEN 'PASS' ELSE 'FAIL' END;
  INSERT INTO batch_evidence_audit SELECT 'Duplicates and null IDs are omitted',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END
    FROM public.read_authorized_report_evidence_ids(other_id,ARRAY[exact_id,exact_id,NULL]);
  INSERT INTO batch_evidence_audit SELECT 'Empty array returns no IDs',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END
    FROM public.read_authorized_report_evidence_ids(owner_id,'{}'::uuid[]);
  INSERT INTO batch_evidence_audit SELECT 'Missing reports return no IDs',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END
    FROM public.read_authorized_report_evidence_ids(owner_id,ARRAY[gen_random_uuid()]);
  INSERT INTO batch_evidence_audit SELECT 'Anonymous RPC execution denied',
    CASE WHEN NOT has_function_privilege('anon','public.read_authorized_report_evidence_ids(uuid,uuid[])','EXECUTE') THEN 'PASS' ELSE 'FAIL' END;
  INSERT INTO batch_evidence_audit SELECT 'Authenticated RPC execution denied',
    CASE WHEN NOT has_function_privilege('authenticated','public.read_authorized_report_evidence_ids(uuid,uuid[])','EXECUTE') THEN 'PASS' ELSE 'FAIL' END;
  INSERT INTO batch_evidence_audit SELECT 'Service RPC execution allowed',
    CASE WHEN has_function_privilege('service_role','public.read_authorized_report_evidence_ids(uuid,uuid[])','EXECUTE') THEN 'PASS' ELSE 'FAIL' END;
  INSERT INTO batch_evidence_audit SELECT 'RPC does not elevate privileges',
    CASE WHEN NOT prosecdef THEN 'PASS' ELSE 'FAIL' END
    FROM pg_proc WHERE oid='public.read_authorized_report_evidence_ids(uuid,uuid[])'::regprocedure;
END $$;
SELECT * FROM batch_evidence_audit;
ROLLBACK;
