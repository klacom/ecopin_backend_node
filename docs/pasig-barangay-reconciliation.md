# PDT-08: Pasig barangay boundary reconciliation

Local implementation and read-only database audit completed on 29 October 2026 (Asia/Manila). No production migration, boundary import or report backfill was applied.

## Evidence and limits

The [PSA PSGC roster](https://psa.gov.ph/classification/psgc/barangays/1381200000) lists 30 Pasig barangays, including San Miguel. The page displayed an as-of date of 31 July 2025 when checked. Ortigas Center is a commercial district, not a 31st barangay. Canonical names/codes and source dates are saved in `data/pasig-barangay-roster.json`.

The configured database contained exactly 30 barangay rows. All polygons were valid/nonempty; every stored display anchor was inside its polygon. All 30 geometries exactly matched the pinned source. No positive-area pair overlaps or holes inside the combined polygon were found. This checks internal topology, not completeness against an independently certified municipal extent.

**The dataset contains only 212 vertices across all 30 polygons.** The [source project](https://github.com/faeldon/philippines-json-maps) describes this medium-resolution derivative as retaining 1% of vertices. It is a reproducible baseline, not certified cadastral/legal boundary evidence. Accurate edge adjudication still requires a higher-resolution LGU-approved dataset and review. No native SHP files or independent legal boundary certification were available in this checkout.

Pinned source commit: `2b823013d15b6d9cb89944ef53a78dccc36c24f7`.

SHA-256: `d2db527be8b911e9dddd24f3d79db97d1e8f305c1d2b11ce5d474ad3e6efa656`.

Artifacts in `data/audits/`: `pdt08-database-boundaries.json` (SELECT-only snapshot), `pdt08-source-boundaries.json` (provenance), `pdt08-source.geojson` (original bytes), `pdt08-reconciliation.json` (GEOS results per barangay). Snapshot timestamps are UTC.

| PSGC | Barangay | Audit result |
| --- | --- | --- |
| 1381200001 | Bagong Ilog | Valid; exact source match |
| 1381200002 | Bagong Katipunan | Valid; exact source match |
| 1381200003 | Bambang | Valid; exact source match |
| 1381200004 | Buting | Valid; exact source match |
| 1381200005 | Caniogan | Valid; exact source match |
| 1381200006 | Dela Paz | Valid; exact source match |
| 1381200007 | Kalawaan | Valid; exact source match |
| 1381200008 | Kapasigan | Valid; exact source match |
| 1381200009 | Kapitolyo | Valid; exact source match |
| 1381200010 | Malinao | Valid; exact source match |
| 1381200011 | Manggahan | Valid; exact source match |
| 1381200012 | Maybunga | Valid; exact source match |
| 1381200013 | Oranbo | Valid; exact source match |
| 1381200014 | Palatiw | Valid; exact source match |
| 1381200015 | Pinagbuhatan | Valid; exact source match |
| 1381200016 | Pineda | Valid; exact source match |
| 1381200017 | Rosario | Valid; exact source match |
| 1381200018 | Sagad | Valid; exact source match |
| 1381200019 | San Antonio | Valid; exact source match |
| 1381200020 | San Joaquin | Valid; exact source match |
| 1381200021 | San Jose | Valid; exact source match |
| 1381200022 | San Miguel | Valid; exact source match |
| 1381200023 | San Nicolas | Valid; exact source match |
| 1381200024 | Santa Cruz | Valid; exact source match |
| 1381200025 | Santa Rosa | Valid; exact source match |
| 1381200026 | Santo Tomas | Valid; exact source match |
| 1381200027 | Santolan | Valid; exact source match |
| 1381200028 | Sumilang | Valid; exact source match |
| 1381200029 | Ugong | Valid; exact source match |
| 1381200030 | Santa Lucia | Valid; exact source match |

## Resulting behavior

- `resolve_report_barangay` returns `resolved`, `border`, `overlap`, `unresolved`, `dataset_incomplete` or `invalid_coordinates`, plus official candidates. Only a unique polygon interior farther than 25 metres from every edge receives a barangay/code. Near outside edges also remain flagged. The 25-metre buffer is a conservative review threshold, not measured positional accuracy; simplified edges can be inaccurate beyond that distance.
- Backend RPC failures produce `unavailable`. Building/geocoder labels and cached addresses cannot override the polygon result. Ortigas Center can be stored separately as `location_district`.
- Report inserts and changes to classification/location/check timestamps are derived again by a database trigger. Legacy rows start as `pending_reconciliation`; they are not silently relabelled during migration. Staff read enrichment clears unconfirmed labels. Existing projections that do not yet expose flags rely on the explicit backfill to clear legacy assignments.
- The compatibility `get_report_barangay` returns NULL for uncertain results. The web address formatter no longer guesses from centroid coordinates.
- Imports require all 30 canonical name/code pairs, valid WGS84 polygons inside a broad Pasig sanity envelope, no area overlaps, reviewed source hash and HTTPS provenance. One database transaction upserts canonical zone IDs and provenance; unexpected existing IDs abort rather than delete data. Importing does not automatically reclassify historic reports. Point-on-surface anchors are for display only.

For analytics, count only `barangay_resolution_status = 'resolved'` in barangay totals. Show all other statuses in an unresolved/review bucket. Do not use stale non-null labels on pending legacy rows.

## Verification

58 focused backend Jest cases pass, including 15 new reconciliation cases and existing citizen/officer/crew urgency regressions. Eight PGlite SQL contract tests pass for migration parsing, resolver decisions, dataset guards, trigger behavior and role restrictions. Those tests explicitly stub spatial primitives and **do not validate real PostGIS geometry behavior or importer execution**. Four web address regressions pass; scoped web lint passes. GEOS/Shapely independently validated the actual stored/source geometries.

`tests/barangay-postgis.sql` is a read-only staging acceptance check for all 30 interior anchors/boundary points, outside/invalid coordinates. It has not been executed against PostGIS. The transactional importer also requires real PostGIS staging verification, including failure rollback, before production use.

## Deployment order and reproducible checks

1. Review and run `migrations/20261029050000_reconcile_pasig_barangay_boundaries.sql` on staging first. Deploy this migration before backend code that selects the new fields. Preserve the snapshot for rollback/reconciliation review.
2. Run `tests/barangay-postgis.sql` using a database owner/service-capable connection. Verify importer success, malformed geometry/overlap rejection and atomic rollback on staging. Resolve any discrepancy before production rollout.
3. Import only after source review. The current database already matches the pinned file, so reimporting identical polygons is optional; it records provenance and replaces display centroids with interior anchors. CLI defaults to dry-run and requires explicit `--confirm`, reviewed `--sha256` and `--source-url` to write.
4. Deploy backend and web. Preview historic report reconciliation using `--dry-run --force`, review border/unresolved cases, then apply the separately authorized backfill. Set the limit high enough to cover intended rows; the existing tool selects newest first and does not paginate. Verify pending/unresolved counts before using barangay analytics as a clean baseline.
5. Obtain an LGU-approved higher-resolution source for precise border adjudication. Re-run the roster/geometry audit, stage the atomic import, and explicitly reconcile affected reports whenever boundaries change.

Read-only/local commands from the backend directory:

```powershell
node scripts/audit-pasig-barangays.mjs --output data/audits/pasig-barangays-db.json
# Requires Shapely in the chosen Python environment (audit tool only).
python scripts/audit-pasig-boundary-geometry.py --help
node scripts/import-pasig-barangay-polygons.mjs --input data/audits/pdt08-source.geojson --dry-run
node scripts/backfill-report-addresses.mjs --dry-run --force --limit=600
```

The audit script reads only `spatial_zones`; it does not export citizen reports or credentials. No new application runtime dependency was added.

## Hosted data audit, 30 October 2026 (read-only)

Checked with SELECT-only queries against the hosted database; nothing was written by the audit.

- 30 barangay polygons present, all valid WGS84, no overlaps, combined area 31.28 km². `pasig_barangay_boundary_source` is **empty**: the polygons were loaded before the importer existed, so no provenance row is recorded. Re-running the importer on `data/audits/pdt08-source.geojson` (already verified as an exact match) records it.
- 577 reports: 576 `pending_reconciliation`, 1 `unresolved`. All 576 carried geocoder-supplied barangay labels, many not Pasig barangays at all (for example Post Proper Northside, East Rembo, Ugong Norte, Highway Hills, San Andres).
- Polygon resolver dry run over all 577: **328 resolved, 73 border, 176 unresolved.**
  - 313 of the 328 resolved agree with the stored label; 15 disagree and all 15 have a stored city other than Pasig City (Mandaluyong, Pateros) on a simplified edge.
  - The 73 border cases are all within a few metres of an edge, as designed.
  - 152 of the 176 unresolved are far outside every polygon (about 1.2 km on average) and their geocoder city is also not Pasig. 24 say Pasig City but fall outside the polygons; 13 of those are within 150 m of an edge.
- The polygons come from a 1%-vertex simplification (212 vertices total). Edge decisions are only as good as that data, so the 24 + 15 + 73 edge cases need a higher-resolution LGU-approved dataset to settle.

### Legacy backfill: `20261030060000_reconcile_legacy_report_barangays.sql`

Replaces labels on rows still `pending_reconciliation` with the resolver's decision. A resolved row gets the polygon barangay and `Pasig City`. Border, overlap, unresolved and invalid rows get no barangay and keep their street text. A polygon hit whose stored city names another city is flagged `border` (reason `city_text_conflict`) instead of forced. Every change is logged in `workflow_private.report_barangay_reconciliation_log` (before and after, readable by the service role only). The run aborts if the boundary dataset is incomplete, and a re-run changes nothing.

It runs with `session_replication_role = replica` so the report triggers (version bump, claim generation, receipts, operational events, lifecycle audit) do not fire for this administrative change. Do not use `backfill-report-addresses.mjs --confirm` for this: it updates through the normal triggers and also re-geocodes every row against external services.

### Address trust rules (PDT-06)

Reverse geocoders return the nearest mapped feature however far away it is, which could glue a neighbouring building's number to the wrong pin. Addresses now follow distance limits from the pin to the matched feature: a house number only within 30 m, a street or landmark only within 100 m, and otherwise no street, so the app shows the GPS pin. Stored addresses created before this rule have not been re-checked.
