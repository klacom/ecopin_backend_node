-- Local fixture input for T08 only: reserved synthetic IDs, owned local database. Idempotent; never touches existing reports.
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.reports WHERE id='a0800000-0000-4000-8000-000000000001' AND title NOT LIKE 'T08_SYNTHETIC_%')
 THEN RAISE EXCEPTION 'Reserved T08 fixture ID is already owned by other data'; END IF;
 IF (SELECT count(*) FROM auth.users WHERE email IN ('citizen-a@parity.ecopin.invalid','officer@parity.ecopin.invalid','crew@parity.ecopin.invalid')
  AND raw_app_meta_data->>'fixture'='ecopin-parity-local')<>3 THEN RAISE EXCEPTION 'Isolated synthetic actors required'; END IF;
END $$;
INSERT INTO public.reports(id,title,description,user_id,location,created_at,status,validation_status,street_address,barangay,city,citizen_landmark,on_private_property)
SELECT 'a0800000-0000-4000-8000-000000000001','T08_SYNTHETIC_CASE',
 'T08_SYNTHETIC_DESCRIPTION: overflowing synthetic bins beside a market stall; a-very-long-unbroken-token-'||repeat('x',160)||E'\nSecond line of the narrative.',
 u.id,extensions.ST_SetSRID(extensions.ST_Point(121.0801,14.5731),4326)::extensions.geography,'2026-11-01 02:00:00Z','unresolved','approved',
 'Synthetic Street 12','Synthetic Barangay','Pasig City','Beside the synthetic blue gate',true
FROM auth.users u WHERE u.email='citizen-a@parity.ecopin.invalid' AND u.raw_app_meta_data->>'fixture'='ecopin-parity-local'
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.cleanup_tasks(id,title,description,status,assigned_crew_ids,created_by,operational_actor_id,report_ids)
SELECT 'a0800000-0000-4000-8000-0000000000a1','T08_SYNTHETIC_TASK','Synthetic case task','pending',ARRAY[c.id],o.id,o.id,ARRAY['a0800000-0000-4000-8000-000000000001'::uuid]
FROM auth.users o CROSS JOIN auth.users c WHERE o.email='officer@parity.ecopin.invalid' AND c.email='crew@parity.ecopin.invalid'
ON CONFLICT(id) DO NOTHING;
UPDATE public.reports SET cleanup_task_id='a0800000-0000-4000-8000-0000000000a1' WHERE id='a0800000-0000-4000-8000-000000000001' AND cleanup_task_id IS NULL;
-- 60 privacy-sensitive activity rows: owner-authored rows must be masked in the case copy; staff rows keep their actor.
INSERT INTO public.audit_logs(report_id,user_id,action_type,action_details,created_at)
SELECT 'a0800000-0000-4000-8000-000000000001',CASE WHEN n%5=0 THEN o.id ELSE u.id END,'manual_note',
 'T08_ACTIVITY_'||lpad(n::text,2,'0')||CASE WHEN n%5=0 THEN ' staff note' ELSE ' citizen-owned entry' END,
 timestamptz '2026-11-01 02:00:00Z'+n*interval '7 minutes'
FROM generate_series(1,60) n CROSS JOIN auth.users u CROSS JOIN auth.users o
WHERE u.email='citizen-a@parity.ecopin.invalid' AND o.email='officer@parity.ecopin.invalid'
 AND NOT EXISTS(SELECT 1 FROM public.audit_logs WHERE action_details LIKE 'T08_ACTIVITY_%');
COMMIT;
-- Incident-scoped milestones through the real journal writer (idempotent by dedupe key).
BEGIN;
SELECT operational_private.emit('arrival','a0800000-0000-4000-8000-0000000000a1','a0800000-0000-4000-8000-000000000001',c.id,1,timestamptz '2026-11-01 03:00:00Z','device_reported','t08-arrival','{"disposition":"on_site"}'::jsonb)
FROM auth.users c WHERE c.email='crew@parity.ecopin.invalid';
SELECT operational_private.emit('completion','a0800000-0000-4000-8000-0000000000a1','a0800000-0000-4000-8000-000000000001',c.id,1,timestamptz '2026-11-01 04:00:00Z','server','t08-completion','{}'::jsonb)
FROM auth.users c WHERE c.email='crew@parity.ecopin.invalid';
COMMIT;
