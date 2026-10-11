BEGIN; SET LOCAL statement_timeout='20s'; SET LOCAL lock_timeout='2s';
CREATE TEMP TABLE email_digest_results(test text,status text) ON COMMIT DROP;
GRANT INSERT,SELECT ON email_digest_results TO service_role,anon,authenticated;
CREATE FUNCTION pg_temp.digest_assert(label text,condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO email_digest_results VALUES(label,CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END); END $$;
DO $$
DECLARE actor uuid; verified uuid; issued uuid; digest text:=encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'); caller text; started timestamptz:=clock_timestamp();
BEGIN
 SELECT id INTO actor FROM public.profiles WHERE role::text='citizen' LIMIT 1;
 SELECT id INTO verified FROM public.profiles WHERE id<>actor LIMIT 1;
 IF actor IS NULL OR verified IS NULL THEN RAISE EXCEPTION 'Missing fixture roles'; END IF;
 UPDATE public.profiles SET is_email_verified=false WHERE id=actor;
 UPDATE public.profiles SET is_email_verified=true WHERE id=verified;
 EXECUTE 'SET LOCAL ROLE service_role';
 BEGIN PERFORM public.issue_email_verification(actor,'bad',24); PERFORM pg_temp.digest_assert('Invalid digest rejected',false); EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.digest_assert('Invalid digest rejected',true); END;
 BEGIN PERFORM public.issue_email_verification(actor,digest,0); PERFORM pg_temp.digest_assert('Zero TTL rejected',false); EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.digest_assert('Zero TTL rejected',true); END;
 BEGIN PERFORM public.issue_email_verification(actor,digest,25); PERFORM pg_temp.digest_assert('Excessive TTL rejected',false); EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.digest_assert('Excessive TTL rejected',true); END;
 BEGIN PERFORM public.issue_email_verification(actor,digest,NULL); PERFORM pg_temp.digest_assert('Null TTL rejected',false); EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.digest_assert('Null TTL rejected',true); END;
 PERFORM pg_temp.digest_assert('Missing profile defers issuance',public.issue_email_verification(gen_random_uuid(),digest,24) IS NULL);
 PERFORM pg_temp.digest_assert('Already verified profile defers issuance',public.issue_email_verification(verified,digest,24) IS NULL);
 issued:=public.issue_email_verification(actor,digest,24);
 PERFORM pg_temp.digest_assert('Valid issuance returns ID',issued IS NOT NULL);
 PERFORM pg_temp.digest_assert('Issued token has no raw secret',(SELECT token IS NULL FROM public.email_verifications WHERE id=issued));
 PERFORM pg_temp.digest_assert('Issued digest is retained',(SELECT token_digest=digest FROM public.email_verifications WHERE id=issued));
 PERFORM pg_temp.digest_assert('Database bounds expiry',(SELECT expires_at>=started+interval '24 hours' AND expires_at<=clock_timestamp()+interval '24 hours' FROM public.email_verifications WHERE id=issued));
 PERFORM pg_temp.digest_assert('Database sets creation timestamp',(SELECT created_at>=started FROM public.email_verifications WHERE id=issued));
 PERFORM pg_temp.digest_assert('Same window defers another issuance',public.issue_email_verification(actor,repeat('a',64),24) IS NULL);
 PERFORM pg_temp.digest_assert('Deferral did not create another row',(SELECT count(*)=1 FROM public.email_verifications WHERE user_id=actor AND created_at>=started));
 BEGIN INSERT INTO public.email_verifications(user_id,token_digest,expires_at) VALUES(verified,digest,now()+interval '1 hour'); PERFORM pg_temp.digest_assert('Duplicate digest rejected',false); EXCEPTION WHEN unique_violation THEN PERFORM pg_temp.digest_assert('Duplicate digest rejected',true); END;
 BEGIN INSERT INTO public.email_verifications(user_id,token,token_digest,expires_at) VALUES(actor,gen_random_uuid(),repeat('b',64),now()+interval '1 hour'); PERFORM pg_temp.digest_assert('Mixed raw and digest storage rejected',false); EXCEPTION WHEN check_violation THEN PERFORM pg_temp.digest_assert('Mixed raw and digest storage rejected',true); END;
 PERFORM pg_temp.digest_assert('Issued row supports atomic completion',public.complete_email_verification(issued,actor));
 EXECUTE 'RESET ROLE';
 FOREACH caller IN ARRAY ARRAY['anon','authenticated'] LOOP
  EXECUTE format('SET LOCAL ROLE %I',caller);
  BEGIN PERFORM 1 FROM public.email_verifications; PERFORM pg_temp.digest_assert('Token table denied: '||caller,false); EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.digest_assert('Token table denied: '||caller,true); END;
  BEGIN PERFORM public.issue_email_verification(actor,digest,24); PERFORM pg_temp.digest_assert('Issuance RPC denied: '||caller,false); EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.digest_assert('Issuance RPC denied: '||caller,true); END;
  EXECUTE 'RESET ROLE';
 END LOOP;
 PERFORM pg_temp.digest_assert('Issuance is invoker with fixed empty search path',(SELECT NOT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid='public.issue_email_verification(uuid,text,integer)'::regprocedure));
END $$;
SELECT * FROM email_digest_results ORDER BY test;
ROLLBACK;
