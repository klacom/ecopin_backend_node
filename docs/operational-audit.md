# PDT-14: discrete operational audit

Status: locally complete after manual Gemini reconciliation, 29 October 2026. Coordinated staging and release remain pending. No hosted migration, deployment, commit or push was performed.

## Contract

The private append-only journal records assignment, acknowledgement, device-reported arrival, evidence submission, completion and cleanup-proof verification, with responsible staff UUIDs. Events retain actor snapshots without profile foreign keys. No reporter IDs, arbitrary action notes or photo URLs are returned. Existing citizen identity hiding and private cleanup notes remain independent of staff attribution.

Admin Audit Logs links to Operational events. Officer Task Details and staff Report Details embed scoped timelines. Officer is web only; Field Crew remains mobile only, using existing investigation receipts. A report scope includes report-associated events only; use Task Details for task-level assignment/acknowledgement history.

Occurrence and server receipt times are distinct. Device GPS claims are not server-attested physical presence. Pages sort by recorded ID, with string bigint cursors. Task turnaround pairs use server timestamps in the latest active assignment generation. Verification pairs match the exact report completion referenced by the publication. Missing pairs remain unknown; historical events are not inferred from updated_at.

The database rejects non-finite and dates outside [2020-01-01 UTC, 10000-01-01 UTC) for both clocks. This is an operational system calendar guard, not historical-data backfill. Device claims also reject malformed/null/future (>5 minutes) times before insertion. Invalid arrival claims do not prevent the underlying valid outcome from being retained; they simply create no arrival milestone. Other invalid server milestone clocks fail transactionally at the journal constraint.

Append-only controls protect application roles, not a database owner who can remove triggers. This is not cryptographically signed or externally anchored storage.

## Manual Gemini findings and reconciliation

The supplied manual review followed the initial fresh-context review. The original manual-gemini-operational-audit-review.md is retained as a pre-fix source snapshot, not the current release contract.

| Finding | Assessment and result |
| --- | --- |
| Non-finite / BC arrivals poison pages | Confirmed. Added finite/calendar ingress guards and a table constraint on occurrence and receipt clocks. Real SQL regressions fail before the repair and pass after it. Web rejects non-finite/BC payloads explicitly. |
| Runtime patcher silently misses writers | Confirmed. Replaced name-only scan with ten exact schema/signature identities, including both public and workflow_private apply_fc_operation. Missing identities, renamed actor/payload parameters, wrong languages and unexpected existing instrumentation fail the migration transaction. Extra overload counts cannot hide omissions. |
| Repeated patch instrumentation | The patch block could duplicate context calls; repaired and tested stable on repetition. The full versioned migration is intentionally one-shot (CREATE TABLE already rejects a rerun). The prior claim that a normal full rerun corrupts functions was overstated. |
| Cursor survives incoming task/report props | Confirmed in an actual mounted React browser test. Key the internal pagination session by incoming entity scope, so the first new request cannot carry the old cursor. Both task and report transitions are covered. |
| Missing task equality in turnaround join | Existing endpoint only returns task turnaround when scoped to one task; query planning does not remove that predicate. No current cross-task bug reproduced. Added explicit task equality as a small defensive clarification. |
| Missing INSERT bridge revocation | Spoofing was already blocked by the trusted-writer trigger. Added INSERT column revocation. PostgreSQL table-level grants still dominate column revocations, so the trigger remains necessary; a regression explicitly grants broad INSERT and proves forged attribution is denied. |

## Verification

- Backend Jest: 43 suites, 389 tests passed.
- PostgreSQL/PGlite: 20 tests across completion writers and prerequisite proof suites passed (13 completion/audit cases). Real canonical receipt, task and offline completion bodies execute; seven additional functions in that fixture are exact-signature patcher-only stubs, not full workflow acceptance.
- New database regressions reproduced four failures before repairs: malformed arrival retention, absent clock checks, repeated patch instability, and missing-writer acceptance. Also tested actor signature drift and forged INSERT with a broad legacy grant.
- Web: 150 unit + 6 deadline tests passed. Next production build and scoped ESLint passed.
- Mounted-component Chromium test first reproduced stale before_id on a new task. It now passes task and report prop transitions without stale cursor requests.
- Production Chromium fixtures passed Admin/Officer at 1440px/light and 320px/dark: six milestones, device/server clocks, scope validation, pagination, server durations, error clearing/retry, no page runtime errors or document horizontal overflow. Fixtures are synthetic, not hosted authorization evidence.

## Coordinated staging and release

1. Confirm PDT-13 prerequisite migrations 20261029140000_require_cleanup_proof.sql, 20261029141000_cleanup_proof_review.sql and 20261029142000_cleanup_completion_writers.sql are present on the intended staging schema.
2. Take a recovery snapshot and apply 20261029150000_operational_event_journal.sql through the versioned migration runner. It checks all ten exact canonical function identities. Drift aborts the transaction; investigate and adapt the migration rather than bypassing the guard or accepting missing audit coverage.
3. Deploy compatible backend and web. New direct writers require the input-only actor columns; deploy the database first. No native change is introduced by PDT-14.
4. Verify actual Supabase/PostgreSQL grants, RLS, PostgREST schema refresh, denied public/citizen/crew reads, staff reads, and forged actor rejection. PGlite does not replace hosted acceptance.
5. Exercise real dispatch/manual assignments, en-route acknowledgement, before/after submission, report receipts, standalone/task completion, offline retry/contested receipts and officer proof verification. Confirm actor IDs, no duplicates, exact completion pairing and no private identity/notes/media leakage.
6. Inspect missing historical data as missing; do not manufacture backfill timestamps. Follow database recovery procedures for any release rollback; do not disable immutable-event controls or erase audit history as a routine fix.

SQL semantics checked against [PostgreSQL date/time functions](https://www.postgresql.org/docs/current/functions-datetime.html) and [column/table privilege revocation](https://www.postgresql.org/docs/current/sql-revoke.html). Hosted staging verification remains mandatory before a production readiness claim.
