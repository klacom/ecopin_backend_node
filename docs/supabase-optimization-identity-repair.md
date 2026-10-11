# Supabase optimization repair: offline identity and conflict isolation

This is the first repair slice from the independent 55-task re-evaluation. It does not certify that all optimization tasks are complete.

Offline operation IDs now bind actor, operation type, entity ID/type, canonical JSON payload and base version. Identical retries still return their original result once. Null identity fields and legacy records without stored request proof fail closed. Immediately before deployment, production had zero operation-log records, so no existing pending replay record was invalidated. Keep operation IDs immutable in the mobile outbox.

Conflict review/resolution remains on sync_conflicts through the trusted backend. RLS is enabled with an explicit service-only policy; client table privileges remain revoked. No rows or settings were changed by this migration.

The exact executed source is migrations/20261011112818_bind_offline_request_identity_and_protect_conflicts.sql. Its contents were compared with the live migration ledger and match. The tested down procedure is in migrations/rollback/ with the same filename. Rollback restores the prior behavior, including its known replay limitations, and should be used only as a deliberate incident recovery decision.

Validation: backend 95 tests pass; historical database suite passes including concurrent claims/version conflicts. npm run test:db:optimization restores the captured schema into a disposable local PostGIS database with synthetic data, reproduces seven failing identity/RLS checks, verifies all 14 after migration, verifies 12 prior workflow assertions, restores exact function definition/ACL/RLS on rollback, then reapplies successfully. All 14 targeted checks also pass live using rolled-back fixtures.

The catalog baseline contains schema definitions only. Auth and Storage in the local verifier are limited test shims; this is not an Auth/password, production data, image or full platform restore drill. The other seven failures from the original forty-check audit remain open.

Run Docker's existing ecopin-slice-a-postgis container before the database tests. The verifier creates and drops only its own generated optimization_test_* database. No database port or credentials are required.
