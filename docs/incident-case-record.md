# PDT-30: printable incident case record

Status: locally complete, 29 October 2026. No hosted migration, deployment, commit or push performed.

## Officer workflow

Open staff Incident Details and choose **Print case record**. The authenticated preview at `/dashboard/raw-data/:id/print` loads a fresh case snapshot. Optional additional access instructions apply to this print copy only and are explicitly labeled; they do not edit the incident or GIS record. Select **Print / Save PDF**, then choose Save as PDF or a physical printer. Use A4 portrait and turn off browser-added headers/footers. Native print rendering preserves Unicode text and selectable text. Long evidence/history continues across A4 pages rather than shrinking the entire case onto one page.

The document contains incident UUID, submission/snapshot timestamps in Manila, response/verification/stage, recorded address, actual pin coordinates, location-precision and unresolved-barangay notices, supplementary citizen landmark, property consent state, approved Before/After images and verification metadata, every recorded operational event and every safe incident activity entry. Missing fields remain explicitly missing. Landmark and print instructions never replace GIS. There is no new reverse geocoder or centroid guess.

## Data and privacy

`GET /api/reports/:id/case-record` is authenticated, suspension-checked and restricted to Officer/Admin at route/controller/database boundaries. It calls service-only `read_incident_case_record(actor,incident_id)`. Its STABLE PostgreSQL function reads one statement snapshot, including report coordinates from reports_view, the privacy-masked report_activity_view and PDT-14 operational_events. The response explicitly lists fields; no raw profile/contact/metadata/photo URLs or event dedupe keys are included. Reporter ownership wins over actor attribution: an actor UUID matching the report owner is masked in both histories, independent of hide_identity and even if the owner is staff. Other staff attribution is retained.

The snapshot includes all incident events plus task-level events from its current task and historical tasks referenced by recorded incident events. Shared task context is labeled and is not asserted to prove an incident-specific action or past membership at every task event. Other reports' events are excluded. Source sequence/order and device/server clocks remain visible. Older missing events are never inferred from updated_at. Activity entries are separate from discrete milestones. Unknown legacy timestamps render as unknown rather than invented dates.

Each stream supports up to 10,000 entries. The database checks one extra entry and rejects larger records with an explicit 422 error, rather than returning a misleading partial export. JSON aggregation avoids PostgREST's ordinary row-page limit.

Photos come only from PDT-13's currently valid, officer-approved, redacted public proof. The snapshot returns publication metadata, never private storage paths. Media URLs are constructed from incident/publication UUIDs using the existing guarded proof endpoint. Both images must download and decode before printing is enabled. Changed/missing/failed proof has no fallback to originals. A genuinely absent publication is printed as unavailable, allowing unresolved incidents to serve as work orders without fabricated completion evidence. Free-text incident narratives/directions can contain personal information; the record is an internal municipal copy, not a new public publication channel.

The preview uses a separate print portal so the dashboard shell, sidebar, alert overlays, controls and duplicate screen copy are excluded. A4 margins, repeated table headings, incident/snapshot margin header and page numbering are verified in current Chromium. Margin headers/page counters depend on browser support; Chromium is the verified target. Printing waits for document fonts. PDF generation uses the browser print dialog, not a server-generated binary download or a new external service.

## Review reconciliation and verification

Fresh-context review found one confirmed defect: the safe activity view masks owner UUIDs for anonymous reports but retains them for disclosed reports, so directly reusing actor attribution exposed a reporter account in the portable copy. The user instructed fixing it and finishing with this review and regression tests. A regression first failed, then passed for hidden/disclosed reports and citizen/staff owners, retaining other staff IDs. No external Gemini review was requested for this reconciliation.

Passed locally:

- Backend Jest: 44 suites / 394 tests.
- PostgreSQL/PGlite: 24 case-record, completion-journal and cleanup-proof tests, including four new case snapshot cases. The case fixture uses a modeled privacy projection; hosted view/grant behavior still needs acceptance.
- Web: 154 unit + 6 deadline tests; scoped ESLint; Next production build.
- Chromium: Officer 1440/light, Admin 1440/dark, Officer 320/dark. Entry link, full rows, zero horizontal overflow, no page runtime errors, print action, optional directions, no-proof state, failed photo, failed snapshot and retry passed.
- Synthetic PDF acceptance: 3-page stress case and 14-page / 140-entry history. Pypdf checks A4 media boxes, every activity marker including the last, Unicode Niño, repeated incident/snapshot headers and page counts, and absence of private sentinels/print controls. Poppler pages rendered and inspected for readable evidence, headings and history. Samples are synthetic test artifacts at ecopin-web/output/pdf/pdt30-*.pdf, not municipal records.

## Release requirements

Apply the PDT-20 safe activity projection, PDT-13 proof migrations and PDT-14 journal before `20261029160000_incident_case_record.sql`, then deploy compatible backend/web. The migration adds only a read function and service-role execution grant. It does not alter case data or backfill history. A missing schema/function fails export with an unavailable state.

Before production acceptance, verify actual Supabase/PostgREST/RLS and suspension/role denial, hidden and disclosed reporter protection, private/withdrawn/reopened proof behavior, historical task context, a real long case and the intended A4 printer/browser. Check that no browser-added URL/time headers or field contact details enter the official copy. Old PDF files are independent snapshots and cannot be revoked after distribution.
