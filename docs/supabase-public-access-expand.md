# Additive report-access repair

Migration 20261011114855_add_safe_public_reports_and_atomic_detail_access adds public_reports and a service-only read_authorized_report_detail RPC. Exact executed SQL is stored with its Supabase-generated version; rollback removes only these additive objects, grants, policy and role.

public_reports exposes approved non-rejected reports. Private-property records require obtained consent and return coordinates rounded to three decimals. Identity, internal notes, photo links/hashes, ML probabilities and sync/version internals are excluded. Its constrained NOLOGIN/NOINHERIT/NOBYPASSRLS owner has only required column reads and is subject to approved/consent RLS. Anonymous and authenticated callers receive SELECT only. Existing detail views remain invoker views.

The detail RPC checks the database's current actor role, owner relationship and active ready-route crew membership in the same SQL snapshot as the read. It does not accept caller-supplied role labels. Only the service role can execute it; the backend forwards the verified user's ID. Private detail remains available to owners, officers/admins and current assigned crew.

Backend report read routes now use the safe projection for public responses and the atomic RPC for detail access. Public responses omit internal activity logs. Evidence reads use the same access decision; public private-property evidence requires authorized detail access. Cluster reads preserve officer/admin detail; other callers receive the public projection. Feeds retain array responses with validated limit/page parameters, a maximum of 500 rows and an X-Has-More header.

Validation: all 112 backend tests pass, including 17 API privacy/pagination tests. All 13 projection and 12 atomic detail tests pass live with rollback fixtures. npm run test:db:public-access starts a fresh, network-isolated PostGIS container, reconstructs the captured schema using synthetic data, verifies the exact migration up/down/up and all 25 contracts, and removes its own container. Readiness waits for the final image server, not its temporary initialization server.

This is the expand phase, not completion of S04/S05. The web map and mobile streams still need caller updates, browser/session verification and bounded viewport behavior. Direct authenticated report access and the old anonymous view path remain until the contract phase. Existing publicly delivered media URLs are a separate recovery/delivery gate. Backend source is prepared locally; production application rollout is not proved by database deployment.
