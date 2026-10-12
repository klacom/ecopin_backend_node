BEGIN;
SET LOCAL statement_timeout = '20s'; 
SET LOCAL lock_timeout = '2s';
CREATE TEMP TABLE email_binding_results(test text, status text) ON COMMIT DROP;
GRANT INSERT, SELECT ON email_binding_results TO service_role, anon, authenticated;

CREATE FUNCTION pg_temp.binding_assert(label text, condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN 
  INSERT INTO email_binding_results VALUES(label, CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END); 
END $$;

DO $$
DECLARE
  u1 uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid();
  u_missing uuid := gen_random_uuid();
  t1_digest text := '1111111111111111111111111111111111111111111111111111111111111111';
  t2_digest text := '2222222222222222222222222222222222222222222222222222222222222222';
  t3_digest text := '3333333333333333333333333333333333333333333333333333333333333333';
  t_unbound_digest text := '4444444444444444444444444444444444444444444444444444444444444444';
  t1_id uuid;
  t2_id uuid;
  t3_id uuid;
  t_unbound_id uuid;
  caller text;
BEGIN
  -- Insert auth.users fixtures
  INSERT INTO auth.users(id, email) VALUES
    (u1, 'alice@example.com'),
    (u2, 'bob@example.com'),
    (u_missing, 'missing@example.com');

  -- Ensure u1 and u2 have unverified citizen profile
  INSERT INTO public.profiles(id, role, is_email_verified) VALUES
    (u1, 'citizen', false),
    (u2, 'citizen', false)
  ON CONFLICT (id) DO UPDATE SET is_email_verified = false, role = 'citizen';

  -- Remove profile for u_missing to explicitly test self-healing
  DELETE FROM public.profiles WHERE id = u_missing;

  EXECUTE 'SET LOCAL ROLE service_role';

  -- Test 1: issue with email binding stores lowercase trimmed email
  t1_id := public.issue_email_verification(u1, t1_digest, 24, '  Alice@Example.COM  ');
  PERFORM pg_temp.binding_assert('Issue stores normalized lowercase email',
    (SELECT issued_to_email = 'alice@example.com' FROM public.email_verifications WHERE id = t1_id));

  -- Test 2: issue with invalid email throws error 22023
  BEGIN
    PERFORM public.issue_email_verification(u1, '9999999999999999999999999999999999999999999999999999999999999999', 24, 'not-an-email');
    PERFORM pg_temp.binding_assert('Invalid email rejected on issue', false);
  EXCEPTION WHEN sqlstate '22023' THEN
    PERFORM pg_temp.binding_assert('Invalid email rejected on issue', true);
  END;

  -- Test 3: issue without email (backward compatibility) leaves issued_to_email NULL
  t_unbound_id := public.issue_email_verification(u2, t_unbound_digest, 24);
  PERFORM pg_temp.binding_assert('Backward compatible 3-arg issue leaves issued_to_email NULL',
    (SELECT issued_to_email IS NULL FROM public.email_verifications WHERE id = t_unbound_id));

  -- Test 4: redemption with email mismatch fails
  PERFORM pg_temp.binding_assert('Redemption with email mismatch fails',
    NOT public.complete_email_verification(t1_id, u1, 'attacker@example.com'));
  PERFORM pg_temp.binding_assert('Token remains unused after email mismatch',
    (SELECT used_at IS NULL FROM public.email_verifications WHERE id = t1_id));
  PERFORM pg_temp.binding_assert('Profile remains unverified after email mismatch',
    NOT (SELECT is_email_verified FROM public.profiles WHERE id = u1));

  -- Test 5: redemption with NULL expected email when token is bound fails
  PERFORM pg_temp.binding_assert('Redemption with NULL expected email fails when token is bound',
    NOT public.complete_email_verification(t1_id, u1, NULL));

  -- Test 6: redemption with matching email (case-insensitive) succeeds
  PERFORM pg_temp.binding_assert('Redemption with matching email succeeds',
    public.complete_email_verification(t1_id, u1, 'ALICE@EXAMPLE.COM'));
  PERFORM pg_temp.binding_assert('Token is marked used after matching redemption',
    (SELECT used_at IS NOT NULL FROM public.email_verifications WHERE id = t1_id));
  PERFORM pg_temp.binding_assert('Profile is verified after matching redemption',
    (SELECT is_email_verified FROM public.profiles WHERE id = u1));

  -- Test 7: unbound token redeems with 2-arg function
  PERFORM pg_temp.binding_assert('Backward compatible 2-arg redemption succeeds for unbound token',
    public.complete_email_verification(t_unbound_id, u2));
  PERFORM pg_temp.binding_assert('Unbound token redemption marks profile verified',
    (SELECT is_email_verified FROM public.profiles WHERE id = u2));

  -- Test 8: Self-healing missing profile
  t3_id := gen_random_uuid();
  INSERT INTO public.email_verifications(id, user_id, token_digest, issued_to_email, expires_at)
  VALUES (t3_id, u_missing, t3_digest, 'missing@example.com', clock_timestamp() + interval '1 hour');

  PERFORM pg_temp.binding_assert('Redemption self-heals missing profile row',
    public.complete_email_verification(t3_id, u_missing, 'missing@example.com'));
  PERFORM pg_temp.binding_assert('Missing profile row was created and verified',
    (SELECT is_email_verified AND role = 'citizen' FROM public.profiles WHERE id = u_missing));

  EXECUTE 'RESET ROLE';

  -- Test 9 & 10: Client permissions denied
  FOREACH caller IN ARRAY ARRAY['anon','authenticated'] LOOP
    EXECUTE format('SET LOCAL ROLE %I', caller);
    BEGIN
      PERFORM public.complete_email_verification(t1_id, u1, 'alice@example.com');
      PERFORM pg_temp.binding_assert('Direct 3-arg complete denied to ' || caller, false);
    EXCEPTION WHEN insufficient_privilege THEN
      PERFORM pg_temp.binding_assert('Direct 3-arg complete denied to ' || caller, true);
    END;

    BEGIN
      PERFORM public.issue_email_verification(u1, t1_digest, 24, 'alice@example.com');
      PERFORM pg_temp.binding_assert('Direct 4-arg issue denied to ' || caller, false);
    EXCEPTION WHEN insufficient_privilege THEN
      PERFORM pg_temp.binding_assert('Direct 4-arg issue denied to ' || caller, true);
    END;
    EXECUTE 'RESET ROLE';
  END LOOP;

  -- Test 11: Search path safety
  PERFORM pg_temp.binding_assert('Functions are invoker with fixed empty search path',
    (SELECT bool_and(NOT prosecdef AND proconfig @> ARRAY['search_path=""'])
     FROM pg_proc WHERE oid IN (
       'public.complete_email_verification(uuid,uuid,text)'::regprocedure,
       'public.issue_email_verification(uuid,text,integer,text)'::regprocedure
     )));

END $$;

SELECT * FROM email_binding_results ORDER BY test;
ROLLBACK;
