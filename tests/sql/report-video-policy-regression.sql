BEGIN;
CREATE TEMP TABLE report_video_policy_check
  (LIKE public.system_settings INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
INSERT INTO report_video_policy_check DEFAULT VALUES;
DO $$
DECLARE candidate smallint;
BEGIN
  IF (SELECT report_video_max_seconds FROM report_video_policy_check LIMIT 1) <> 10 THEN
    RAISE EXCEPTION 'Expected the existing default maximum to be 10 seconds';
  END IF;
  FOREACH candidate IN ARRAY ARRAY[5, 7, 10]::smallint[] LOOP
    UPDATE report_video_policy_check SET report_video_max_seconds = candidate;
  END LOOP;
  FOREACH candidate IN ARRAY ARRAY[4, 11]::smallint[] LOOP
    BEGIN
      UPDATE report_video_policy_check SET report_video_max_seconds = candidate;
      RAISE EXCEPTION 'Out-of-range video maximum was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
  END LOOP;
  BEGIN
    UPDATE report_video_policy_check SET report_video_max_seconds = NULL;
    RAISE EXCEPTION 'Null video maximum was accepted';
  EXCEPTION WHEN not_null_violation THEN NULL;
  END;
END;
$$;
ROLLBACK;
