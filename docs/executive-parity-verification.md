# T04 isolated executive verification

Verified 3 November 2026. No report implementation rewrite or hosted migration was needed: the candidate already registers the missing executive route and invokes the hosted-compatible SQL restored locally in T03.

## Fixture scope

`supabase/fixtures-executive-t04.sql` loads six reserved synthetic report IDs into the owned isolated database. It does not disable constraints, RLS or triggers. The transaction refuses IDs owned by other data and is repeatable without duplicating reports. There are no production records or real citizen images in this fixture.

The September/October/November boundary cases deliberately use Manila calendar boundaries:

- September 30 at 15:59:59 UTC stays in September.
- September 30 at 16:00 UTC is October 1 in Manila and is included.
- October 31 at 16:00 UTC is November 1 in Manila and is excluded from October.

Expected October totals: four submissions, two approved, one rejected, one pending; three processed outcomes. Current all-time backlog is four, including September and November rows; it must not be labeled October month-end backlog. One resolved fixture gives a 48-hour median/average/P90. All locations remain explicitly unassigned because the isolated platform has no imported administrative boundary polygons. No polygons or resolved geographic assignments are fabricated. These are aggregate fixtures, not acceptance of report submission, cleanup-proof completion or geographic reconciliation workflows.

## Local services

The clean web checkout is at `C:/dev/ecopin/.tmp/parity-recovery-web`. Use only the isolated candidate backend, local Supabase project and synthetic users established in T02/T03. The original backend on port 4002 remains the existing escalation owner and is not part of this test server.

`scripts/serve-isolated-executive.mjs` starts the real API registrations on `127.0.0.1:4102` by importing app.js, without index.js or its background writers. It also exposes a local TLS REST adapter for the real isolated Redis store. No report response, backend authentication or database RPC is mocked on the successful path.

Setup used the cached `redis/redis-stack-server` image, container `ecopin-parity-session`, published only at `127.0.0.1:63791`. The TLS adapter listens only at `127.0.0.1:9443`. Its commands execute against that Redis instance, so session encryption, session reads and admission Lua execute through the real web session code. This is an isolated compatibility adapter, not verification of a hosted Redis provider.

Create short-lived localhost key/certificate files under ignored `.private/t04`, with SANs for localhost and 127.0.0.1. Generate ignored `.private/t04/session.json` with a fresh base64url token (at least 32 random bytes) and a separate 32-byte encryption key. The clean web `.env.local` uses only:

- `FRONTEND_URL=https://localhost:4101`, `BACKEND_API_URL=http://127.0.0.1:4102`.
- Local Supabase configuration and the TLS adapter URL for both session-store and quota-store settings.
- The local adapter token and separate encryption key, never copied production values.

Start the API/adapter from the backend candidate. Start Next from the web candidate with port 4101, host 127.0.0.1, `--webpack`, and the `--experimental-https-key`, `--experimental-https-cert` **and `--experimental-https-ca`** flags pointing to the local certificate files. Set `NODE_EXTRA_CA_CERTS` to that local certificate. The CA flag is required because Next's HTTPS worker replaces that environment setting with its configured root CA. No TLS verification was disabled in the application. The dedicated test browser accepts this local self-signed certificate only in its disposable context.

## Verification

```powershell
# Backend, after fixture load through the owned local Docker database:
npm test -- --runInBand --runTestsByPath tests/barangay-executive.test.js tests/barangay-analytics-api.test.js --silent
node scripts/serve-isolated-executive.mjs
# Web, in another terminal with the isolated server running:
node --test --test-isolation=none tests/barangay-executive.test.mjs
$env:ECOPIN_PLAYWRIGHT_PATH='C:\dev\ecopin\.tmp\deadline-tools\node_modules\playwright'
$env:ECOPIN_CHROMIUM_PATH='C:\Users\murasakino\AppData\Local\ms-playwright\chromium-1234\chrome-win64\chrome.exe'
node tests/executive-parity-integrated.browser.cjs
```

Existing focused suites pass: 18 backend cases and four web cases. The web fixtures now carry the already reviewed roster locally instead of requiring a particular sibling checkout layout.

The new integration passed 33 checks using real officer/admin web login, encrypted Redis-backed session cookies, the actual web proxy, actual backend authentication/roles and actual local SQL. It reconciles October and backlog/resolution totals, checks all 30 official areas plus unassigned and city totals, rejects raw fixture details/identities in aggregates, and confirms signed-out and authenticated citizen/crew denial. Desktop/mobile output has no document overflow or page runtime exceptions. Draft-month print disablement, stale snapshot blocking, unavailable response clearing and retry recovery pass. Stale/failure responses are injected only after the successful real path; they supplement rather than replace integration evidence.

Native officer and admin A4 PDFs each have nine pages. The stale snapshot produces only a one-page not-ready notice, including when native PDF printing is invoked directly. All pages were rendered for visual inspection; text extraction confirms month/counts, official area coverage and absence of controls/private sentinels, and word bounds stay inside every page. Chromium's font encoding causes extractor spacing/font-descriptor warnings; rendered text and tables were visually checked instead of treating extraction alone as layout evidence.

Artifacts are in the web candidate's generated, untracked `output/t04`: results.json, pdf-checks.json, synthetic PDFs, desktop/mobile screenshots and a rendered PDF contact sheet. They are synthetic test evidence, not municipal reports. Optional historical hotspot analysis is unavailable in this isolated environment and is clearly printed as unavailable; no zero hotspot count or production inference success is claimed. Local SMTP is not configured for this task; its startup connectivity warning is not an executive-report failure. Production report acceptance remains T15.
