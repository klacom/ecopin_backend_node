# Citizen-provided landmarks

Create Report → Details has an optional **Nearby landmark** textbox, limited to 300 characters. It is a visual hint for responders, separate from the selected map pin/GPS coordinates, geocoding, barangay reconciliation, priority and severity. It never enters those calculations or replaces an address. Review and authorized citizen/officer/crew/web report details label it **Citizen-provided landmark** or **extra directions**.

The shared multipart creation and offline batch APIs accept nullable `citizen_landmark`. Missing, null or whitespace-only input stores NULL; other input must be text of at most 300 Unicode code points. Invalid input is rejected before creation. Text is stored/displayed as plain text. Rejected-report copy/prefill retains the hint so the citizen can revise it before submitting a new report.

The native queue upgrades Drift v9→v10 with a nullable `citizenLandmark` column. Older drafts retain their original coordinates, media, ownership and privacy choices, with an empty landmark. Online requests, queued requests, blocked-urgency recovery and cached report JSON retain the hint independently. Existing street address, barangay and city values now also survive report-model serialization; the round-trip test exposed their prior omission.

## Database rollout

Local migration: `migrations/20261029110000_citizen_landmark.sql`. Applied to EcoPin `wcruoyygungqxazdwhtv` through Supabase on 29 October 2026, hosted ledger version **20261029081919**, name **citizen_landmark**. Compare the hosted entry by name; do not reapply the same migration under its local timestamp.

It adds nullable `reports.citizen_landmark` and a length constraint, then appends the field to the existing operational view. View owner `ecopin_operational_reader`, masking, grants and `security_barrier=true` remain intact. The public map projection is unchanged and does not gain this field. No historical report or geometry backfill is performed. Free text can identify its author if they include personal information, as with the existing report description.

A live transaction verified storing/reading a synthetic hint, unchanged coordinates and barangay, operational-view delivery and oversized-input rejection. All test writes were rolled back. The hosted catalog confirms the field on reports/operational view, its absence from the public projection and unchanged view ownership/options.

## Verification and release

- 355 backend Jest tests pass, including input validation, online rejection and offline persistence independent of the point. Nine focused PostgreSQL/PGlite migration/privacy tests pass, including view ownership/masks and unchanged GIS values.
- 38 focused Flutter tests pass: contact navigation above a nested role bar, 320px/large-text contact/forms, landmark prefill/edit/review/submission, transport coordinates, offline recovery, legacy-draft upgrade and model caching.
- Production web build passes. Synthetic officer 1440px/light and admin 320px/dark browser checks confirm the hint renders in authorized details while identity masking remains intact, with no overflow/runtime errors.
- Focused UI/model analysis is run separately. Broader database/API analysis reports ten pre-existing informational style findings in unchanged code; the existing web report detail has two pre-existing video-playback `no-console` lint errors. No checks were suppressed.

The additive database migration is live. Backend/web release and a mobile build/install are still required on separately hosted instances/devices. No physical-device navigation/dialer check, actual citizen submission or app-store/APK release was performed.
