-- Controlled aggregate fixtures only; run through the owned local Docker database.
BEGIN;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.reports WHERE id::text LIKE 'a0400000-%' AND title NOT LIKE 'PRIVATE_T04_%')
 THEN RAISE EXCEPTION 'Reserved fixture IDs are already owned by other data'; END IF; END $$;
INSERT INTO public.reports(id,title,description,user_id,location,created_at,status,validation_status,lgu_resolved_at,cleanup_action_notes)
SELECT v.id::uuid,'PRIVATE_T04_TITLE_SENTINEL_'||v.n,'PRIVATE_T04_DESCRIPTION_SENTINEL',u.id,
 extensions.ST_SetSRID(extensions.ST_Point(121.08,14.60),4326)::extensions.geography,
 v.created_at::timestamptz,v.status::public.report_status,v.validation::public.report_validation_status,
 v.resolved_at::timestamptz,CASE WHEN v.resolved_at IS NOT NULL THEN 'Synthetic cleanup for aggregate verification' END
FROM (VALUES
 ('a0400000-0000-4000-8000-000000000001',1,'2026-09-30 15:59:59Z','unresolved','approved',NULL),
 ('a0400000-0000-4000-8000-000000000002',2,'2026-09-30 16:00:00Z','unresolved','approved',NULL),
 ('a0400000-0000-4000-8000-000000000003',3,'2026-10-15 04:00:00Z','resolved','approved','2026-10-17 04:00:00Z'),
 ('a0400000-0000-4000-8000-000000000004',4,'2026-10-20 00:00:00Z','unresolved','manual_review',NULL),
 ('a0400000-0000-4000-8000-000000000005',5,'2026-10-25 00:00:00Z','rejected','rejected',NULL),
 ('a0400000-0000-4000-8000-000000000006',6,'2026-10-31 16:00:00Z','unresolved','approved',NULL)
)v(id,n,created_at,status,validation,resolved_at)
CROSS JOIN auth.users u WHERE u.email='citizen-a@parity.ecopin.invalid' AND u.raw_app_meta_data->>'fixture'='ecopin-parity-local'
ON CONFLICT(id) DO NOTHING;
DO $$ BEGIN IF (SELECT count(*) FROM public.reports WHERE id::text LIKE 'a0400000-%')<>6 THEN RAISE EXCEPTION 'Fixture load incomplete'; END IF; END $$;
COMMIT;
