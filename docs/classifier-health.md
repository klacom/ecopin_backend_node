# Classifier health: cold starts, not an outage (T13, 3 November 2026)

## Finding

The intermittent "classifier unavailable" health result is a **serverless cold start**, demonstrated from production evidence gathered read-only on 3 November 2026.

- Production backend (PM2 `backend`, release `5fc531d`) uses `USE_AWS_CLASSIFIER=true`; the classifier endpoint is the API Gateway route in front of the container Lambda `clip-validator` (3008 MB, 120 s timeout, container image, **no provisioned concurrency, no reserved concurrency**, redeployed 2 Nov 13:59 UTC). Endpoint values are deliberately not recorded.
- The backend health check sent a GET to that same endpoint with a **5 s** budget and treated any non-answer as "unavailable". On the host, 12 probes five seconds apart showed the first two returning `DEGRADED / classifier unavailable` (6.8 s and 5.5 s) and the remaining ten `OK` in 0.3-0.9 s. The Lambda log shows two cold containers initialising at exactly those moments (11:00:34 and 11:00:45 UTC): **the probe itself triggered the cold starts**, then recovery was automatic.
- Lambda `INIT_REPORT` records: 14 of 14 cold starts in the retained window hit `Phase: init Status: timeout` at 10.0 s. The model load exceeds Lambda's 10 s initialisation limit, so initialisation is repeated inside the first invocation. Resulting first-answer times: typically **about 18-19 s (10 s of initialisation plus 8-9 s)**, 17.8 s on the first record, 13.2 s after the 2 Nov redeploy; and **79 s, 56 s and 41 s in a burst on 2 Nov at 09:12-09:13 UTC (17:12 Manila)**, when several cold containers started at once. Warm health GETs take milliseconds, warm classifications 0.2-0.4 s (the backend log's p50 is 254 ms); memory use reaches about 2.15 GB.
- The three burst invocations (79 s, 56 s, 41 s) exceed the backend client's **30 s** timeout (`classifierClient.service.js`), so a caller waiting on them would have timed out and failed. That burst precedes the 17:24 Manila commit `75f0567` ("route incomplete image validation to officer review") by about twelve minutes, which fits the earlier classifier-outage recovery but is **not proven to be the same event**: the backend's current PM2 out log holds only 19 classifier requests (19 HTTP 200, one slow response of 25.5 s, p50 254 ms) and no `[ClassifierClient] FAILED` line, it does not cover the 2 Nov 09:12 UTC window, and the local backend on port 4002 shares the production configuration and may have called the same endpoint.
- **Controlled inference** through the production release's own client and endpoint with synthetic images (flat gray, gradient, random noise; five requests, warm): every response satisfied the contract (allowed class, confidence in range, probabilities object, decision string, review-zone boolean, allowed category or null), 217-401 ms, deterministic for identical images (gray and gradient identical across repeats: INVALID/REJECTED at 0.044), noise landed in the manual-review band (INVALID/MANUAL_REVIEW at 0.384). So reachability, warmth and inference output are independently shown healthy; correct output on real waste photographs was not assessed (only synthetic images were permitted).

No persistent inference failure was found.

## What changed in the candidate

- `src/services/classifier-health.js`: the health probe now distinguishes **warming** (no answer inside the 5 s budget while that is still within the observed cold-start range: at most six consecutive timeouts and 90 s) from **unavailable** (refused or unresolvable connection, any error answer, or silence beyond that range). `warming` does not degrade the overall status. `GET /health` keeps `dependencies.classifier` (now `available | warming | unavailable | not_configured | error`) and adds `probes.classifier` with the outcome, latency, consecutive timeouts and last success time (no URL, no body).
- `scripts/check-classifier-inference.mjs`: real synthetic inference through the backend's client for release acceptance (non-zero exit on a contract failure or a first answer slower than 30 s).
- Tests: `tests/classifier-health.test.js` (15, deterministic clock), `scripts/verify-classifier-health-isolated.mjs` (real endpoint against a loopback stand-in that is silent for 12 s: refused = outage, cold = warming then available, 503 = outage).

## Acceptance limits and monitoring (what "healthy enough" means)

| Signal | Source | Acceptable | Investigate |
| --- | --- | --- | --- |
| Warm answer time | `[ClassifierClient]` response lines, Lambda `REPORT` | p95 under 1 s | p95 over 3 s |
| First answer after idle | Lambda `REPORT` duration where `INIT_REPORT` precedes | up to 25 s | over 30 s: **it exceeds the backend client budget; the report falls back to officer review** |
| Any invocation over 30 s | Lambda `REPORT` | none | each occurrence |
| Init timeouts per day | `INIT_REPORT ... Status: timeout` | informational (each is one cold start) | rising trend or more than one burst of three in an hour |
| Failed classifications | `[ClassifierClient] FAILED` in the backend log | none per day | any |
| Health | `probes.classifier` | `available`, or `warming` for at most one probe cycle | `unavailable` on two probes at least 60 s apart, or `consecutive_timeouts >= 3` |

Read-only queries used for this evidence (reuse them): `aws logs filter-log-events` on `/aws/lambda/clip-validator` with patterns `INIT_REPORT` and `REPORT`; `grep` of the PM2 out log for `ClassifierClient` counts and latency; `aws lambda list-provisioned-concurrency-configs`.

## Open decision (not made here; service change, own task)

The cold start is real and will recur after idle periods. Options, none applied: reduce initialisation below 10 s (load the model lazily or shrink the image); one unit of provisioned concurrency (continuous cost for a 3 GB function, check current pricing); a scheduled warm-up invocation (cheap, not a guarantee, and must not rely on the health GET); or accept it, relying on the officer-review fallback and the limits above. Any change to the Lambda, its gateway or its schedule is a production service change and needs the owner's decision and its own test and rollback. The backend client timeout (30 s) should not be raised in the request path; a user submitting a report should not wait on a cold model load.
