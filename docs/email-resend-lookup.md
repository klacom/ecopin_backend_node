# Bounded email verification user lookup

Migration `20261011160011_bound_email_verification_user_lookup`, verified 12 October 2026 Asia/Manila.

## Problem and behavior

Resend previously called Auth `listUsers()` without pagination and searched only that first page. A valid unverified account beyond the page was silently missed. The controller also compared addresses without normalization and separately retrieved a profile.

Resend now normalizes a bounded email string and calls the service-only `find_email_verification_user` RPC. It returns one UUID or null. The private reader uses equality against the existing `auth.idx_users_email` index and considers at most two matching Auth rows. Any ambiguity is denied before profile eligibility is considered, including when one matching user is already verified. Missing profiles and verified users are ineligible. The issuance function still rechecks current verification status and cooldown under the profile lock.

The public wrapper is SECURITY INVOKER. Its private helper is SECURITY DEFINER, owned by postgres, with an empty search path and fully qualified tables. Both functions restrict execution to service_role; the existing private-schema usage permission is reused. No managed Auth tables, indexes, schema grants or table privileges are altered. The backend retains no raw Auth metadata from the lookup.

Malformed types, oversized inputs, multiple at signs and internal whitespace return HTTP 400 before lookup. Missing request bodies return the existing required-email error. Missing, verified, ambiguous and deferred accounts, and lookup/issuance/SMTP failures retain the same generic HTTP 200 response. Dependency error objects are not logged.

## Verification

- Independent reproduction failed against the original implementation: nine focused cases; all sixteen cases failed after adding malformed inputs. A subsequent missing-body case reproduced TypeError while the first sixteen passed; its guard fixed it.
- Full backend suite: 190 tests passed across 28 suites.
- Nineteen rollback-only live SQL assertions passed, including eligible lookup, normalized address, verified exclusion, invalid input and anon/authenticated execution denial.
- Fresh isolated database: nineteen checks passed before and after rollback/reapplication; seven additional assertions cover large population, ambiguity, missing profile, caller search path, state preservation and recovery.
- Synthetic Auth population: 10,009 rows. The inner bounded query used idx_users_email beneath Limit, returned one row and recorded three shared buffer hits and 0.068 ms execution time. This verifies an index-compatible shape; it is not a before/after production or endpoint latency benchmark.
- Live Auth users, profiles, tokens, settings and Auth/profile table ACL fingerprints remained unchanged. Zero invalid indexes and zero failed cron runs in the last 24 hours.
- Real HTTP checks use only null, unknown and malformed inputs. Anonymous RPC calls are denied; null/unknown service lookups return null; the local unknown resend response remains generic. No real email or Auth confirmation is performed.

SQL source matches the live ledger's single statement: 1,663 characters, MD5 `b2e72c4e1cb5f96fae3721c4287173a5`.

## Recovery

Revert the resend controller before applying the paired rollback SQL. Rollback drops the public wrapper and private helper, without changing data or prior privileges. Leaving the new controller after dropping the RPC safely stops resend issuance; its generic response makes that deployment ordering important. Reverting to the old controller also restores its first-page limitation.

From the backend root, replay in an isolated container:

```powershell
node scripts/test-email-resend-lookup.mjs migrations/20261011160011_bound_email_verification_user_lookup.sql migrations/rollback/20261011160011_bound_email_verification_user_lookup.sql tests/sql/email-resend-lookup-regression.sql
```

The verifier uses a limited Auth shim and recreates the captured email index only in that disposable database. It does not prove full Supabase Auth recovery or real email delivery.

## Remaining scope

Issued-email binding, the cross-system Auth/profile completion gap, expired-token retention, per-IP/bot controls and real user journeys remain open. The generic response limits status/body enumeration but does not prove equal response timing. All 55 original optimization acceptance gates remain active.

The implementation follows [Supabase database function security](https://supabase.com/docs/guides/database/functions#security-definer-vs-invoker). The original admin method supports [paginated user listing](https://supabase.com/docs/reference/javascript/auth-admin-listusers); a full paginated scan would still transfer unrelated Auth records and grow with the user count.
