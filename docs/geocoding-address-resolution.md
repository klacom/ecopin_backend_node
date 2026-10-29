# Geographic address resolution

PDT-08 (29 October 2026) separates descriptive addresses from administrative classification. See [Pasig reconciliation](pasig-barangay-reconciliation.md) for the audit, dataset limitations and deployment steps.

`src/services/geocoding.service.js` obtains street/landmark descriptions from local building footprints, optional ArcGIS, Photon and Nominatim. Those descriptions do not establish the barangay. Even a complete building result must pass polygon resolution. External city labels remain descriptive; an outside point receives no Pasig barangay.

`resolve_report_barangay(lat,lng)` validates the complete canonical 30-barangay dataset and uses PostGIS polygon containment. Border points and points within 25 metres of any polygon edge remain unassigned with candidates. Overlapping interiors, missing/invalid datasets and outside points also remain unassigned with an explicit status. This replaces the previous nearest-centroid fallback. The buffer is a review policy, not a measured accuracy guarantee.

`get_report_barangay` remains a compatibility wrapper returning a name only for a resolved result. A database trigger independently derives report classifications from the stored location and ignores supplied barangay/status/candidates/check timestamps. Existing reports start as `pending_reconciliation` until explicitly backfilled.

San Miguel is an official barangay. Ortigas Center is a commercial district and may be retained in `location_district`; it never replaces the polygon-derived barangay. Landmarks and school/compound names belong in descriptive address fields.

Street results can be cached, but every cache hit rechecks the current polygon classification. Cache keys preserve the full coordinate values. RPC failures return `unavailable` with no barangay. The web formatter uses supplied names and resolution metadata, displays review notices where available, and never calculates a nearest-centroid barangay. Legacy non-Pasig descriptive addresses can still be displayed.

## Maintenance

Run commands from the backend directory after deploying the migration:

```powershell
node scripts/backfill-report-addresses.mjs --dry-run --force --limit=600
```

Choose a limit covering the intended dataset; the script selects the newest records first and does not paginate. Review the dry-run before separately applying with `--confirm`. A confirmed backfill updates report addresses and may invoke existing workflow/audit triggers. Recheck remaining `pending_reconciliation` counts afterwards. Do not treat a successful dry-run as completed reconciliation. Boundary imports and address backfills are separate operations; neither was performed live for PDT-08.
