BEGIN;
ALTER TABLE public.system_settings
  ADD COLUMN report_video_max_seconds smallint NOT NULL DEFAULT 10
  CONSTRAINT system_settings_report_video_max_seconds_check CHECK (report_video_max_seconds BETWEEN 5 AND 10);
COMMENT ON COLUMN public.system_settings.report_video_max_seconds IS
  'Admin-controlled maximum report video duration in seconds. Minimum clip duration remains 5 seconds.';
COMMIT;
