# T05 isolated operations verification

Scope: the existing operational journal/history and polling feed, using the T02/T03 isolated database and T04 API/session/web setup. No hosted migration or production deployment is part of this task.

## Discovered failure and correction

The actual field-crew `PATCH /api/cleanup-tasks/:id/status` returned 500 when changing pending to en_route. Both that branch and desk status overrides supplied `updated_at`, which does not exist on the audited cleanup_tasks table. Two regression cases reproduced the schema failure before the fix. Remove that field from these two payloads and supply the authenticated operational_actor_id in the desk branch as well. The existing row-context trigger records the responsible account and clears the input-only actor field. No table, trigger, grant or policy change is needed.

The controller regression slice passes 34 tests across cleanup-task-read, operational-events and live-operations. The preserved database tests were adapted from their original node:test imports to the repository's Jest runner, without dropping cases; all five pass. Eight web contract tests pass. The final normal backend suite has 276 passing tests, four failed assertions and the inherited email-verification suite-load failure: three failing suites total (email-verification, field-report-photo and merge-resolution). Those remain release blockers; no clean full-suite result is claimed.

## Reproduction and verification

From the isolated backend candidate:

```powershell
npm test -- --runInBand --runTestsByPath tests/cleanup-task-read.test.js tests/operational-events.test.js tests/live-operations.test.js tests/live-operations-db.test.mjs --silent
```

From the isolated web candidate, with its HTTPS server and isolated API running:

```powershell
node --test --test-isolation=none tests/operational-events.test.mjs tests/live-operations.test.mjs
$env:ECOPIN_PLAYWRIGHT_PATH='C:/dev/ecopin/.tmp/deadline-tools/node_modules/playwright'
$env:ECOPIN_CHROMIUM_PATH='C:/Users/murasakino/AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe'
node tests/operations-parity-integrated.browser.cjs
```

The web's ignored local environment needs `NEXT_PUBLIC_BACKEND_API_URL=http://127.0.0.1:4102` alongside the T04 settings. Existing backendFetch maps this absolute backend origin to the authenticated same-origin proxy. An absent value makes older dashboard callers request an undefined path; a same-origin proxy URL can be rewritten twice, and a relative value is rejected by next.config serviceOrigin. Use the actual isolated backend origin. This setting correction is local test setup only.

The browser harness first verifies the Docker engine, project label and exact candidate workdir, plus the fixture's loopback URL. It loads `supabase/fixtures-operations-t05.sql` through that owned database only. Each run creates two fresh synthetic task UUIDs assigned to the marked synthetic crew. Constraints, triggers and RLS remain enabled. It never resets the append-only journal; tasks/events from diagnostic attempts remain as synthetic local history. The fixture does not submit photos, complete real work, touch production or fabricate geography.

The controlled event uses real field-crew backend login and the actual status route. Staff pages use real web login, Redis-backed encrypted sessions, web proxy, backend authentication and database functions. The automatic 20-second poll must deliver the new transition exactly once, and repeating the same status mutation must not add events. Task/report filtering and intersection, bigint-safe pagination, private cache headers, attribution and restricted feed projection are checked against actual API results. Citizen/crew history/feed requests and signed-out proxy access must be denied.

Only after the real path succeeds does the harness inject stale/503 responses for browser failure testing. The feed identifies a retained snapshot, retries to real data, labels stale data and disables refresh offline. Failed history clears previous rows and retry restores the real scope. The officer opens the existing task-history disclosure; admin uses task/report filters. Screenshots/results are generated under web `output/t05`, outside committed source.

A repeated Next development `Manifest file is empty` error interrupted task-page navigation during verification. The isolated worker/launcher were identified by port, parent PID and command line before restart. Its generated `.next` directory was moved to the evidence directory (`t05-next-cache`) before a fresh rebuild; source files and original working trees were preserved. Record the final browser outcome in the shared recovery evidence rather than treating an interrupted attempt as acceptance.

The isolated API health still reports its unavailable classifier while its database is available and background jobs are disabled. Classifier recovery is T13; this task makes no production inference claim. The original production escalation owner on port 4002 must remain until T15 handover. Production history/feed acceptance remains T15.
