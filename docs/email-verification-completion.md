# Email verification completion

The old controller returned HTTP 200 after resolved Supabase profile/Auth errors and after zero-row profile updates. Two requests that both observed an unused token also both reported success. Four independent mocked reproduction tests failed before this repair.

Migration `20261011152906_atomically_complete_email_verification` and the matching controller change require a checked Auth result, then atomically verify an existing profile and consume its token. The service-only invoker function locks the verification row and rechecks its user, expiry and used state after any lock wait. A missing profile returns false without consuming the token; a profile write error aborts both database writes. Only a literal true RPC result produces success. Malformed token shapes are rejected before privileged work, verification responses are not cached, and dependency errors cannot echo token details into logs.

Auth confirmation remains an external idempotent operation preceding the database transaction. A later database failure can leave Auth confirmed while the local profile is unverified and its link remains unused. The existing backend login profile gate remains necessary. This change does not make Auth and Postgres one transaction, bind a legacy link to its issued email, or secure raw token storage. Token digests, email binding, distributed throttling, retention and complete real-user journeys remain S02 work.

Verification on 11 October 2026:

- All 160 backend tests in 26 suites passed, including 13 isolated verification tests. Email/Auth/network are mocked in these tests.
- A fresh disposable PostGIS reconstruction passed 14 SQL assertions before and after rollback/reapplication. Rollback restored function absence.
- Two separate database connections produced exactly one success. The test first observed the successful transaction holding its lock, then observed the second connection waiting on that lock.
- Missing-profile and injected profile-error checks left the token unused; the error check also left the profile unverified. Synthetic Auth shim rows exist only inside the disposable local container.
- All 14 live rollback-only assertions passed. Live counts stayed at 49 reports, 7 tasks, 9 profiles, 8 verification rows and 6 verified profiles; the system-settings hash was unchanged. No real email was sent or real Auth user confirmed.
- Executed source matches the single live ledger statement exactly: MD5 `86197faab7a8aa749a4ad31d3c3ffc47`.
- Real HTTP rejected anonymous RPC invocation (401/42501), returned false for null service arguments, and rejected unknown/malformed local verification links (400). Verification responses used `Cache-Control: no-store`. These checks did not redeem a real user token.

Run `node scripts/test-email-completion.mjs` to reproduce the fresh database drill. It removes only its own generated container. Revert the matching controller before dropping the function in an emergency rollback; otherwise completion fails closed. Restoring the old controller reopens the documented false-success and race defects.

The security advisor still reports the already reviewed limited-owner public map view and disabled leaked-password protection; this migration adds no new security advisory. Function access follows [Supabase database function guidance](https://supabase.com/docs/guides/database/functions).
