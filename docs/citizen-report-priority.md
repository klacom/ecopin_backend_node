# PDT-01: citizen report priority

Scope: Flutter citizen Create Report + shared API. Citizen web reporting is deferred by agreement. Priority is a citizen request, separate from calculated severity and operational dispatch priority. Officer urgency decisions, trust scoring, scheduling changes, and automatic escalation are outside PDT-01.

## Submission contract

`POST /api/reports` (multipart) and `POST /api/reports/sync/batch` (each JSON report) accept:

| Field | Values / validation |
| --- | --- |
| `citizen_priority` | `urgent` or `non_urgent`; omitted/null for legacy clients |
| `priority_reason` | Required for Urgent: `community_event` (Community Event/Liga), `school_hospital_zone` (School/Hospital Zone), `severe_obstruction` (Severe Obstruction), `public_health_hazard` (Public Health Hazard) |
| `priority_explanation` | Optional text, maximum 1000 characters; surrounding whitespace trimmed |

Non-urgent clears reason/explanation to null. Invalid online input returns 400 with `message`; sync returns an item-level error without insertion. Legacy submissions remain unspecified rather than being retroactively labeled Non-urgent. Repeated sync uses the existing idempotency key.

The mobile Details step defaults to Non-urgent and offers tap-to-select priority/reasons. Urgent cannot advance without a preset reason, including through step navigation. The review summary shows the choice, reason and optional explanation. Offline drafts preserve these fields through SQLite schema version 7 and upload them on sync; version 6 drafts retain their data and unspecified priority.

Urgent requests need officer verification; this change does not approve urgency or guarantee a response time. The existing severity inputs/defaults and calculation remain unchanged. The obsolete AI severity claim has been removed from the review screen.

## Release order

1. Apply `migrations/add_citizen_report_priority.sql` to the target database.
2. Deploy the shared API, then release the updated mobile application.
3. Smoke-test online and offline Urgent/Non-urgent submissions against the deployed service.

The SQL is additive and leaves historical records unspecified. Do not deploy the client first: an older API would ignore the new fields. No live migration, backend deployment or APK release is included in this local implementation.

## Local validation

- Backend tests: `npm test -- --runInBand tests/citizen-priority.test.js tests/citizen-priority-sync.test.js tests/report-evidence-batching.test.js`.
- Flutter tests: `flutter test test/reports/report_priority_test.dart test/reports/offline_priority_test.dart test/ui/offline_report_receipt_test.dart test/ui/create_report_flow_test.dart`.
- Coverage includes preset validation, optional explanation, malformed input, compatibility, online payloads, offline storage, schema upgrade, sync/idempotency, navigation gating, review and failed-submit retention.
- Results: 33 Flutter tests and 26 backend tests passed across targeted runs. Priority controls were checked at 320, 768, 1024 and 1440 pixels in light/dark themes with 2x text. Analysis of changed Dart files found no errors or warnings; 10 existing informational lint findings remain in the database/API files.
- Live Postgres constraints, deployed service behavior and physical-device acceptance remain release checks.
