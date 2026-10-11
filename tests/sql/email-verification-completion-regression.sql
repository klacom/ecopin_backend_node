BEGIN;
SET LOCAL statement_timeout='20s'; SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE email_completion_results(test text,status text) ON COMMIT DROP;
GRANT INSERT,SELECT ON email_completion_results TO service_role,anon,authenticated;
CREATE FUNCTION pg_temp.email_assert(label text,condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO email_completion_results VALUES(label,CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END); END $$;
DO $$
DECLARE actor uuid; stranger uuid; valid_id uuid:=gen_random_uuid(); expired_id uuid:=gen_random_uuid(); boundary_id uuid:=gen_random_uuid(); caller text;
BEGIN
  SELECT id INTO actor FROM public.profiles WHERE role::text='citizen' LIMIT 1;
  SELECT id INTO stranger FROM public.profiles WHERE id<>actor LIMIT 1;
  IF actor IS NULL OR stranger IS NULL THEN RAISE EXCEPTION 'Missing fixture roles'; END IF;
  UPDATE public.profiles SET is_email_verified=false WHERE id=actor;
  INSERT INTO public.email_verifications(id,user_id,expires_at) VALUES
    (valid_id,actor,clock_timestamp()+interval '1 hour'),
    (expired_id,actor,clock_timestamp()-interval '1 second'),
    (boundary_id,actor,clock_timestamp());
  EXECUTE 'SET LOCAL ROLE service_role';
  PERFORM pg_temp.email_assert('Wrong user cannot consume token',NOT public.complete_email_verification(valid_id,stranger));
  PERFORM pg_temp.email_assert('Wrong user leaves profile unverified',NOT (SELECT is_email_verified FROM public.profiles WHERE id=actor));
  PERFORM pg_temp.email_assert('Unknown token fails',NOT public.complete_email_verification(gen_random_uuid(),actor));
  PERFORM pg_temp.email_assert('Null token fails',NOT public.complete_email_verification(NULL,actor));
  PERFORM pg_temp.email_assert('Expired token fails',NOT public.complete_email_verification(expired_id,actor));
  PERFORM pg_temp.email_assert('Expiry boundary fails',NOT public.complete_email_verification(boundary_id,actor));
  PERFORM pg_temp.email_assert('Expiry failure does not consume token',(SELECT used_at IS NULL FROM public.email_verifications WHERE id=expired_id));
  PERFORM pg_temp.email_assert('Valid token completes',public.complete_email_verification(valid_id,actor));
  PERFORM pg_temp.email_assert('Completion verifies existing profile',(SELECT is_email_verified FROM public.profiles WHERE id=actor));
  PERFORM pg_temp.email_assert('Completion consumes token',(SELECT used_at IS NOT NULL FROM public.email_verifications WHERE id=valid_id));
  PERFORM pg_temp.email_assert('Repeat redemption fails',NOT public.complete_email_verification(valid_id,actor));
  EXECUTE 'RESET ROLE';
  FOREACH caller IN ARRAY ARRAY['anon','authenticated'] LOOP
    EXECUTE format('SET LOCAL ROLE %I',caller);
    BEGIN
      PERFORM public.complete_email_verification(valid_id,actor);
      PERFORM pg_temp.email_assert('Direct invocation denied: '||caller,false);
    EXCEPTION WHEN insufficient_privilege THEN
      PERFORM pg_temp.email_assert('Direct invocation denied: '||caller,true);
    END;
    EXECUTE 'RESET ROLE';
  END LOOP;
  PERFORM pg_temp.email_assert('Function is invoker with fixed empty search path',
    (SELECT NOT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid='public.complete_email_verification(uuid,uuid)'::regprocedure));
END $$;
SELECT * FROM email_completion_results ORDER BY test;
ROLLBACK;
