BEGIN;
SET LOCAL statement_timeout='20s'; SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE email_lookup_results(test text,status text) ON COMMIT DROP;
GRANT INSERT,SELECT ON email_lookup_results TO service_role,anon,authenticated;
CREATE FUNCTION pg_temp.lookup_assert(label text,condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO email_lookup_results VALUES(label,CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END); END $$;
DO $$
DECLARE actor uuid; address text; caller text;
BEGIN
  SELECT u.id,u.email INTO actor,address FROM auth.users u JOIN public.profiles p ON p.id=u.id
  WHERE u.email IS NOT NULL AND u.email=lower(btrim(u.email))
    AND length(u.email) BETWEEN 3 AND 254 AND u.email ~ '^[^[:space:]@]+@[^[:space:]@]+$'
    AND (SELECT count(*) FROM auth.users other WHERE other.email=u.email)=1 LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'No suitable fixture identity'; END IF;
  UPDATE public.profiles SET is_email_verified=false WHERE id=actor;
  EXECUTE 'SET LOCAL ROLE service_role';
  PERFORM pg_temp.lookup_assert('Existing unverified user found',public.find_email_verification_user(address)=actor);
  PERFORM pg_temp.lookup_assert('Case and surrounding spaces normalize',public.find_email_verification_user('  '||upper(address)||'  ')=actor);
  PERFORM pg_temp.lookup_assert('Unknown account returns null',public.find_email_verification_user('missing-'||gen_random_uuid()::text||'@example.invalid') IS NULL);
  PERFORM pg_temp.lookup_assert('Null input returns null',public.find_email_verification_user(NULL) IS NULL);
  PERFORM pg_temp.lookup_assert('Empty input returns null',public.find_email_verification_user('') IS NULL);
  PERFORM pg_temp.lookup_assert('Overlong input returns null',public.find_email_verification_user(repeat('a',255)||'@example.invalid') IS NULL);
  PERFORM pg_temp.lookup_assert('Missing domain returns null',public.find_email_verification_user('invalid@') IS NULL);
  PERFORM pg_temp.lookup_assert('Multiple at signs return null',public.find_email_verification_user('a@b@c') IS NULL);
  PERFORM pg_temp.lookup_assert('Newline input returns null',public.find_email_verification_user(E'a@example.invalid\nBcc: other@example.invalid') IS NULL);
  PERFORM pg_temp.lookup_assert('SQL metacharacters are literal',public.find_email_verification_user(''' OR true --@example.invalid') IS NULL);
  EXECUTE 'RESET ROLE';
  UPDATE public.profiles SET is_email_verified=true WHERE id=actor;
  EXECUTE 'SET LOCAL ROLE service_role';
  PERFORM pg_temp.lookup_assert('Verified user returns null',public.find_email_verification_user(address) IS NULL);
  EXECUTE 'RESET ROLE';
  UPDATE public.profiles SET is_email_verified=NULL WHERE id=actor;
  EXECUTE 'SET LOCAL ROLE service_role';
  PERFORM pg_temp.lookup_assert('Null verification flag remains eligible',public.find_email_verification_user(address)=actor);
  EXECUTE 'RESET ROLE';
  FOREACH caller IN ARRAY ARRAY['anon','authenticated'] LOOP
    EXECUTE format('SET LOCAL ROLE %I',caller);
    BEGIN PERFORM public.find_email_verification_user(address); PERFORM pg_temp.lookup_assert('Public RPC denied: '||caller,false);
    EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.lookup_assert('Public RPC denied: '||caller,true); END;
    BEGIN PERFORM workflow_private.find_email_verification_user(address); PERFORM pg_temp.lookup_assert('Private helper denied: '||caller,false);
    EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.lookup_assert('Private helper denied: '||caller,true); END;
    EXECUTE 'RESET ROLE';
  END LOOP;
  PERFORM pg_temp.lookup_assert('Public wrapper is invoker with fixed search path',
    (SELECT NOT prosecdef AND provolatile='s' AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid='public.find_email_verification_user(text)'::regprocedure));
  PERFORM pg_temp.lookup_assert('Private reader is definer with fixed search path',
    (SELECT prosecdef AND provolatile='s' AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid='workflow_private.find_email_verification_user(text)'::regprocedure));
  PERFORM pg_temp.lookup_assert('Service still cannot read Auth table',NOT has_table_privilege('service_role','auth.users','SELECT'));
END $$;
SELECT * FROM email_lookup_results ORDER BY test;
ROLLBACK;
