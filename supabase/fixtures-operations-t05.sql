-- Local fixture input: task_a/task_b are fresh test UUIDs, never existing task IDs.
BEGIN;
DO $$ BEGIN
 IF (SELECT count(*) FROM auth.users WHERE email IN ('officer@parity.ecopin.invalid','crew@parity.ecopin.invalid')
  AND raw_app_meta_data->>'fixture'='ecopin-parity-local')<>2 THEN
  RAISE EXCEPTION 'Isolated synthetic actors required';
 END IF;
END $$;
INSERT INTO public.cleanup_tasks(id,title,description,status,assigned_crew_ids,created_by,operational_actor_id)
SELECT v.id::uuid,'Synthetic T05 operations fixture','Controlled local history/feed verification','pending',ARRAY[c.id],o.id,o.id
FROM (VALUES (:'task_a'),(:'task_b')) v(id)
CROSS JOIN auth.users o CROSS JOIN auth.users c
WHERE o.email='officer@parity.ecopin.invalid' AND c.email='crew@parity.ecopin.invalid';
COMMIT;
