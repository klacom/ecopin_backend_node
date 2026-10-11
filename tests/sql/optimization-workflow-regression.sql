BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '15s';
CREATE TEMP TABLE ecopin_workflow_audit(test text, status text, detail text) ON COMMIT DROP;
GRANT INSERT ON ecopin_workflow_audit TO service_role;
DO $audit$
DECLARE
  owner_id uuid; officer_id uuid; crew_id uuid; rid uuid:=gen_random_uuid(); rid2 uuid:=gen_random_uuid();
  note_op text:='ecopin-audit-'||gen_random_uuid()::text;
  detail_op text:='ecopin-audit-'||gen_random_uuid()::text;
  result jsonb; replay jsonb; before_deadline timestamptz; before_sla timestamptz;
  ver bigint; after_ver bigint; row_count integer; grouped integer; noise integer;
  selected_issue text; selected_severity text; cid uuid;
BEGIN
  SELECT id INTO owner_id FROM public.profiles WHERE role::text='citizen' LIMIT 1;
  SELECT id INTO officer_id FROM public.profiles WHERE role::text='officer' LIMIT 1;
  SELECT id INTO crew_id FROM public.profiles WHERE role::text='field_crew' LIMIT 1;
  SELECT issue_type::text INTO selected_issue FROM public.reports WHERE issue_type IS NOT NULL LIMIT 1;
  SELECT e.enumlabel INTO selected_severity FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid WHERE t.typname='cluster_severity' ORDER BY e.enumsortorder LIMIT 1;
  INSERT INTO public.reports(id,user_id,title,issue_type,location,severity_score)
    VALUES (rid,owner_id,'EcoPin rollback audit fixture',selected_issue::public.report_issue_type,
      extensions.st_setsrid(extensions.st_makepoint(121,14),4326),2),
      (rid2,owner_id,'EcoPin rollback audit fixture',selected_issue::public.report_issue_type,
      extensions.st_setsrid(extensions.st_makepoint(121.0001,14),4326),2);
  SELECT deadline_at,sla_started_at,fc_version INTO before_deadline,before_sla,ver FROM public.reports WHERE id=rid;
  INSERT INTO ecopin_workflow_audit SELECT 'New report lifecycle initialized',
    CASE WHEN lifecycle_state='fresh' AND deadline_at>sla_started_at AND sla_started_at IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    'Fresh state and future SLA deadline' FROM public.reports WHERE id=rid;
  UPDATE public.reports SET notes='Rollback fixture note' WHERE id=rid;
  INSERT INTO ecopin_workflow_audit SELECT 'Ordinary report edit preserves SLA',
    CASE WHEN deadline_at=before_deadline AND sla_started_at=before_sla THEN 'PASS' ELSE 'FAIL' END,
    'Deadline and SLA start compared before/after note edit' FROM public.reports WHERE id=rid;
  UPDATE public.reports SET severity_score=5 WHERE id=rid;
  INSERT INTO ecopin_workflow_audit SELECT 'Severity edit preserves activated SLA',
    CASE WHEN deadline_at=before_deadline AND sla_started_at=before_sla THEN 'PASS' ELSE 'FAIL' END,
    'Deadline compared after legacy deadline trigger and lifecycle trigger' FROM public.reports WHERE id=rid;
  SELECT fc_version INTO ver FROM public.reports WHERE id=rid;
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  SET LOCAL ROLE service_role;
  BEGIN
    result:=public.apply_fc_operation(officer_id,note_op,'fc.note.add',rid,'report','{"action":"Rollback audit note"}'::jsonb,ver);
    replay:=public.apply_fc_operation(officer_id,note_op,'fc.note.add',rid,'report','{"action":"Rollback audit note"}'::jsonb,ver);
    SELECT count(*) INTO row_count FROM public.audit_logs WHERE report_id=rid AND action_details='Rollback audit note';
    INSERT INTO ecopin_workflow_audit VALUES ('Offline note compatibility alias and exact replay',
      CASE WHEN result->>'status'='success' AND replay->>'replayed'='true' AND row_count=1 THEN 'PASS' ELSE 'FAIL' END,
      'One audit row for original plus identical replay');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO ecopin_workflow_audit VALUES ('Offline note compatibility alias and exact replay','FAIL',SQLSTATE||': '||SQLERRM);
  END;
  BEGIN
    replay:=public.apply_fc_operation(officer_id,note_op,'fc.note.add',rid,'report','{"action":"Different rollback audit note"}'::jsonb,ver);
    INSERT INTO ecopin_workflow_audit VALUES ('Operation ID reuse with changed payload rejected','FAIL',
      'Changed payload accepted as replay; replayed='||coalesce(replay->>'replayed','null'));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO ecopin_workflow_audit VALUES ('Operation ID reuse with changed payload rejected',
      CASE WHEN SQLSTATE IN ('42501','22023') THEN 'PASS' ELSE 'REVIEW' END,SQLSTATE||': '||SQLERRM);
  END;
  BEGIN
    result:=public.apply_fc_operation(officer_id,detail_op,'fc.report.update_details',rid,'report','{"notes":"New rollback fixture note"}'::jsonb,ver);
    SELECT fc_version INTO after_ver FROM public.reports WHERE id=rid;
    INSERT INTO ecopin_workflow_audit VALUES ('Offline report edit accepts current version and increments it',
      CASE WHEN result->>'status'='success' AND after_ver=ver+1 THEN 'PASS' ELSE 'FAIL' END,'Current-version update tested');
    replay:=public.apply_fc_operation(officer_id,'ecopin-audit-'||gen_random_uuid()::text,'fc.report.update_details',rid,'report','{"notes":"Stale rollback fixture note"}'::jsonb,ver);
    INSERT INTO ecopin_workflow_audit VALUES ('Offline report edit rejects stale version',
      CASE WHEN replay->>'status'='conflict' THEN 'PASS' ELSE 'FAIL' END,'Distinct operation with previous version tested');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO ecopin_workflow_audit VALUES ('Offline report version checks','FAIL',SQLSTATE||': '||SQLERRM);
  END;
  BEGIN
    result:=public.apply_fc_operation(crew_id,'ecopin-audit-'||gen_random_uuid()::text,'fc.note.add',rid,'report','{"action":"Unassigned rollback audit note"}'::jsonb,ver);
    INSERT INTO ecopin_workflow_audit VALUES ('Unassigned field crew note denied','FAIL','Unassigned write accepted');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO ecopin_workflow_audit VALUES ('Unassigned field crew note denied',CASE WHEN SQLSTATE='42501' THEN 'PASS' ELSE 'REVIEW' END,SQLSTATE||': '||SQLERRM);
  END;
  RESET ROLE;
  BEGIN
    SELECT count(*) FILTER(WHERE cluster_id IS NOT NULL),count(*) FILTER(WHERE cluster_id IS NULL)
      INTO grouped,noise FROM public.dbscan_reports(50,2) WHERE id=ANY(ARRAY[rid,rid2]);
    INSERT INTO ecopin_workflow_audit VALUES ('DBSCAN groups nearby fixtures at 50 meters',
      CASE WHEN grouped=2 AND noise=0 THEN 'PASS' ELSE 'FAIL' END,'Two points approximately 11 meters apart');
    SELECT count(*) FILTER(WHERE cluster_id IS NULL) INTO noise FROM public.dbscan_reports(5,2) WHERE id=ANY(ARRAY[rid,rid2]);
    INSERT INTO ecopin_workflow_audit VALUES ('DBSCAN separates fixtures at 5 meters',
      CASE WHEN noise=2 THEN 'PASS' ELSE 'FAIL' END,'Meter-scale threshold tested using projected CRS');
    cid:=public.upsert_cluster_for_reports_v2(ARRAY[rid,rid2],selected_issue,selected_severity,50);
    SELECT count(*) INTO row_count FROM public.reports WHERE id=ANY(ARRAY[rid,rid2]) AND cluster_id=cid AND lifecycle_state='clustered';
    INSERT INTO ecopin_workflow_audit VALUES ('Cluster creation links reports and updates lifecycle',
      CASE WHEN row_count=2 THEN 'PASS' ELSE 'FAIL' END,'Two fixture reports attached to new cluster');
    BEGIN
      cid:=public.upsert_cluster_for_reports_v2(ARRAY[rid,rid2],selected_issue,selected_severity,50);
      INSERT INTO ecopin_workflow_audit VALUES ('Cluster creation rejects already clustered snapshot','FAIL','Stale snapshot accepted');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO ecopin_workflow_audit VALUES ('Cluster creation rejects already clustered snapshot',
        CASE WHEN SQLERRM='Clustering snapshot is stale' THEN 'PASS' ELSE 'REVIEW' END,SQLSTATE||': '||SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO ecopin_workflow_audit VALUES ('Spatial fixture workflow','FAIL',SQLSTATE||': '||SQLERRM);
  END;
END;
$audit$;
SELECT * FROM ecopin_workflow_audit;
ROLLBACK;
