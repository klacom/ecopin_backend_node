# Release verification: identity and role-aware features (T14b)

A green `/health` shows that a process answers and the database is reachable. It does not show **which release** answers, or that **the recovered handlers are registered**: most routers sit behind shared authentication, so a missing handler looks like `401` to an unauthenticated probe. This is how production reported OK while the executive, history, support, case-record, directions and crew-summary routes were absent.

## Identity

- The CI build writes the commit SHA into `RELEASE` and includes it in the immutable artifact (`.github/workflows/deploy.yml`).
- The process reads `RELEASE` once (`src/services/release-identity.js`) and `/health` publishes `release: { sha, source, started_at }`. `source` is `artifact`, `absent` or `invalid`; a SHA is never guessed.
- `scripts/deploy/deploy-backend.sh` now runs `identity_ok` after the health wait and **before** `current` is repointed: health must report the selected SHA, `pm2` must show `backend` online running from the selected release directory, and afterwards `current` must resolve to the selected release. Any mismatch triggers the script's existing rollback. Older immutable releases that predate `RELEASE` (used for rollback) are accepted on directory and process alone, with a message saying so.

## Features

`node scripts/verify-release.mjs --base <url> --expect-sha <sha> [--require-escalation] [--lenient] [--classifier-optional] [--skip-identity] [--json]`

Role sessions are taken from the environment, never argv: `VERIFY_TOKEN_OFFICER`, `VERIFY_TOKEN_ADMIN`, `VERIFY_TOKEN_CITIZEN`, `VERIFY_TOKEN_FIELD_CREW`. A role without a session **fails** its features (`no_credentials`); nothing is skipped silently.

The manifest (`scripts/lib/release-verification.mjs`, read-only GET probes, no request bodies) covers T04-T11 with an authorised-role probe for each feature and an unauthorised-role probe where the feature is staff-only:

| Outcome | Meaning |
| --- | --- |
| `pass` | Expected status for that role |
| `missing_route` | The backend 404 handler answered (`route_not_found`): the release does not register the route |
| `access_leak` | A role that must be refused (403) got 200 |
| `unexpected_status` | Registered, but not the strict acceptance answer (for example 503 `missing_prerequisite`: a migration is absent) |
| `no_credentials` | No session for that role; the feature is unverified |
| `release_mismatch` / `release_unreported` | A different release answers / the process reports no identity |

Health checks in the same run: database available, classifier `available` or `warming` (T13), and with `--require-escalation` the T11 job registered. `--lenient` accepts any non-missing answer for authorised probes (registration only); acceptance uses the default strict mode.

## Where it runs

- Candidate CI: `npm test` runs `tests/release-verification.test.js` (manifest, omitted routes, mismatches) and `tests/release-identity.test.js` (RELEASE parsing and the real identity snippet of the deploy script).
- Development matrix: `node scripts/verify-release-isolated.mjs` (isolated stack, synthetic accounts) and `node scripts/verify-release-negative-isolated.mjs` (the real app with a router genuinely unregistered, and wrong/absent identity).
- Production (T15): run the CLI on the host or from an approved workstation against the production URL with sessions for the **designated** officer, admin, citizen and field-crew accounts, `--expect-sha <selected SHA> --require-escalation`. Acceptance requires exit code 0 with no skipped identity.
