-- Test reconstruction only; never apply this fixture as a production migration.
-- Captured EcoPin effective platform grants on 11 October 2026:
-- extensions schema: anon/authenticated/service_role have USAGE;
-- spatial_ref_sys: PUBLIC has SELECT. PostGIS geometry JSON serialization
-- reads this lookup table under the caller's role.
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
GRANT SELECT ON extensions.spatial_ref_sys TO PUBLIC;
