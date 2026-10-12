-- Representative Application Journeys Execution Plans & Performance Baseline (P01-P05, P09, G02)

-- 1. Owner Feed (P01)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, title, description, status, validation_status, created_at
FROM public.reports
WHERE user_id = (SELECT id FROM public.profiles WHERE role = 'citizen' LIMIT 1)
ORDER BY created_at DESC
LIMIT 20;

-- 2. Moderation Pending Queue (P01, P09)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, title, status, validation_status, issue_type, created_at
FROM public.reports
WHERE validation_status = 'pending'
ORDER BY created_at ASC
LIMIT 50;

-- 3. Dispatch Work Queue (P02, P03)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, title, status, route_status, assigned_crew_ids, created_at
FROM public.cleanup_tasks
WHERE status IN ('created', 'pending') AND route_status = 'ready'
ORDER BY created_at ASC
LIMIT 50;

-- 4. Spatial Proximity / Viewport Search (G01, G02, G04)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status
FROM public.reports
WHERE extensions.ST_DWithin(
  location::extensions.geography,
  extensions.ST_SetSRID(extensions.ST_MakePoint(121.05, 14.55), 4326)::extensions.geography,
  5000
)
LIMIT 50;

-- 5. Citizen Unread Notifications Feed (P04, P07)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, type, title, body, created_at
FROM public.notifications
WHERE user_id = (SELECT id FROM public.profiles WHERE role = 'citizen' LIMIT 1)
  AND is_read = false
ORDER BY created_at DESC
LIMIT 20;

-- 6. Task Assignment Receipts Join (P03, P05)
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.id, t.title, t.status, r.id AS receipt_id, r.assignment_generation
FROM public.cleanup_tasks t
JOIN public.field_assignment_receipts r ON r.task_id = t.id
WHERE t.route_status = 'ready'
LIMIT 50;
