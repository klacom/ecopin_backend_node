BEGIN;
ALTER TABLE public.system_settings DROP COLUMN report_video_max_seconds;
COMMIT;
