-- Local fixture input for T10 only: reserved synthetic IDs in the owned local database. Idempotent; existing tasks/reports are untouched.
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.cleanup_tasks WHERE id::text LIKE 'a1000000-%' AND title NOT LIKE 'T10_SYNTHETIC_%') THEN RAISE EXCEPTION 'Reserved T10 IDs owned by other data'; END IF;
 IF (SELECT count(*) FROM auth.users WHERE email IN ('officer@parity.ecopin.invalid','crew@parity.ecopin.invalid') AND raw_app_meta_data->>'fixture'='ecopin-parity-local')<>2 THEN RAISE EXCEPTION 'Isolated synthetic actors required'; END IF;
END $$;
INSERT INTO public.field_crews(id,name,member_profile_ids,team_lead_profile_id,depot_location)
SELECT 'a1000000-0000-4000-8000-0000000000c1','T10_SYNTHETIC_CREW',ARRAY[c.id],c.id,extensions.ST_SetSRID(extensions.ST_Point(121.075,14.565),4326)::extensions.geography
FROM auth.users c WHERE c.email='crew@parity.ecopin.invalid' ON CONFLICT(id) DO NOTHING;
-- Three tasks: completed on 2026-11-02 (Manila), failed on 2026-11-02 with a failure note, and still open (created 2026-11-02).
INSERT INTO public.cleanup_tasks(id,title,description,status,assigned_crew_ids,created_by,operational_actor_id,created_at)
SELECT v.id::uuid,v.title,'T10 synthetic','pending',ARRAY[c.id],o.id,o.id,v.created_at::timestamptz
FROM (VALUES ('a1000000-0000-4000-8000-0000000000a1','T10_SYNTHETIC_COMPLETED','2026-11-02 00:30:00Z'),
 ('a1000000-0000-4000-8000-0000000000a2','T10_SYNTHETIC_FAILED','2026-11-02 00:40:00Z'),
 ('a1000000-0000-4000-8000-0000000000a3','T10_SYNTHETIC_OPEN','2026-11-02 00:50:00Z')) v(id,title,created_at)
CROSS JOIN auth.users o CROSS JOIN auth.users c WHERE o.email='officer@parity.ecopin.invalid' AND c.email='crew@parity.ecopin.invalid' ON CONFLICT(id) DO NOTHING;
UPDATE public.cleanup_tasks SET status='completed',completion_result='cleanup_completed',completion_notes='T10 synthetic cleanup notes',before_photo_url='storage://Cleanup%20Originals/a1000000-0000-4000-8000-0000000000a1/before/t10-b.jpg',after_photo_url='storage://Cleanup%20Originals/a1000000-0000-4000-8000-0000000000a1/after/t10-a.jpg',before_photo_hash='t10-b',after_photo_hash='t10-a',completed_at='2026-11-02 09:00:00Z',completed_by=(SELECT id FROM auth.users WHERE email='crew@parity.ecopin.invalid')
 WHERE id='a1000000-0000-4000-8000-0000000000a1' AND status::text<>'completed';
UPDATE public.cleanup_tasks SET status='completed',completion_result='failed',completed_at='2026-11-02 10:00:00Z',failure_class='site',failure_reason='T10 synthetic: gate locked, no contact',
 completed_by=(SELECT id FROM auth.users WHERE email='crew@parity.ecopin.invalid')
 WHERE id='a1000000-0000-4000-8000-0000000000a2' AND status::text<>'completed';
-- Manila day boundaries: completed 2026-11-01 16:00:00Z (= 00:00 on 2 Nov), 2026-11-02 15:59:59Z (= 23:59:59 on 2 Nov) and 2026-11-02 16:00:00Z (= 00:00 on 3 Nov).
INSERT INTO public.cleanup_tasks(id,title,description,status,assigned_crew_ids,created_by,operational_actor_id,created_at)
SELECT v.id::uuid,v.title,'T10 synthetic boundary','pending',ARRAY[c.id],o.id,o.id,'2026-10-20 00:00:00Z'
FROM (VALUES ('a1000000-0000-4000-8000-0000000000a4','T10_SYNTHETIC_EDGE_START'),('a1000000-0000-4000-8000-0000000000a5','T10_SYNTHETIC_EDGE_END'),('a1000000-0000-4000-8000-0000000000a6','T10_SYNTHETIC_EDGE_NEXT')) v(id,title)
CROSS JOIN auth.users o CROSS JOIN auth.users c WHERE o.email='officer@parity.ecopin.invalid' AND c.email='crew@parity.ecopin.invalid' ON CONFLICT(id) DO NOTHING;
UPDATE public.cleanup_tasks t SET status='completed',completion_result='failed',completed_at=v.at::timestamptz,completed_by=(SELECT id FROM auth.users WHERE email='crew@parity.ecopin.invalid')
FROM (VALUES ('a1000000-0000-4000-8000-0000000000a4','2026-11-01 16:00:00Z'),('a1000000-0000-4000-8000-0000000000a5','2026-11-02 15:59:59Z'),('a1000000-0000-4000-8000-0000000000a6','2026-11-02 16:00:00Z')) v(id,at)
WHERE t.id=v.id::uuid AND t.status::text<>'completed';
-- Approved route with a stop for the completed task.
INSERT INTO public.optimization_runs(id,triggered_by,status,criteria,approved_by,approved_at)
SELECT 'a1000000-0000-4000-8000-0000000000b1',o.id,'approved','{}'::jsonb,o.id,'2026-11-02 00:00:00Z' FROM auth.users o WHERE o.email='officer@parity.ecopin.invalid' ON CONFLICT(id) DO NOTHING;
INSERT INTO public.crew_routes(id,optimization_run_id,crew_id,start_depot,end_depot)
VALUES('a1000000-0000-4000-8000-0000000000d1','a1000000-0000-4000-8000-0000000000b1','a1000000-0000-4000-8000-0000000000c1',
 extensions.ST_SetSRID(extensions.ST_Point(121.075,14.565),4326)::extensions.geography,extensions.ST_SetSRID(extensions.ST_Point(121.075,14.565),4326)::extensions.geography) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.route_waypoints(id,crew_route_id,sequence_order,latitude,longitude,cleanup_task_id,waypoint_type)
VALUES('a1000000-0000-4000-8000-0000000000e1','a1000000-0000-4000-8000-0000000000d1',1,14.5731,121.0801,'a1000000-0000-4000-8000-0000000000a1','task') ON CONFLICT(id) DO NOTHING;
-- Access blocks: one open, one cleared inside the period.
INSERT INTO public.dispatch_access_blocks(id,report_id,task_id,reason,failure_class,blocked_by,blocked_at,cleared_by,cleared_at,clearance_notes)
SELECT v.id::uuid,'a0800000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-0000000000a2',v.reason,'site',c.id,v.blocked_at::timestamptz,v.cleared_by,v.cleared_at::timestamptz,v.notes
FROM (VALUES ('a1000000-0000-4000-8000-0000000000f1','T10 synthetic open block','2026-11-02 02:00:00Z',NULL::uuid,NULL,NULL),
 ('a1000000-0000-4000-8000-0000000000f2','T10 synthetic cleared block','2026-11-01 02:00:00Z',(SELECT id FROM auth.users WHERE email='officer@parity.ecopin.invalid'),'2026-11-02 03:00:00Z','Gate opened by barangay')) v(id,reason,blocked_at,cleared_by,cleared_at,notes)
CROSS JOIN auth.users c WHERE c.email='crew@parity.ecopin.invalid' ON CONFLICT(id) DO NOTHING;
-- Server-time journal events on 2026-11-02 (Manila): an assignment and a verification of the T09 proof publication.
SELECT operational_private.emit('assignment','a1000000-0000-4000-8000-0000000000a1',NULL,o.id,1,timestamptz '2026-11-02 01:00:00Z','server','t10-assign','{"assigned":true}'::jsonb)
FROM auth.users o WHERE o.email='officer@parity.ecopin.invalid';
SELECT operational_private.emit('verification','a0900000-0000-4000-8000-0000000000a1'::uuid,'a0900000-0000-4000-8000-000000000001',o.id,1,timestamptz '2026-11-02 05:00:00Z','server','t10-verify',
 jsonb_build_object('publication_id',(SELECT id FROM public.cleanup_proof_publications WHERE report_id='a0900000-0000-4000-8000-000000000001')))
FROM auth.users o WHERE o.email='officer@parity.ecopin.invalid' AND EXISTS(SELECT 1 FROM public.cleanup_proof_publications WHERE report_id='a0900000-0000-4000-8000-000000000001');
COMMIT;
