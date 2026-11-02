# Isolated development and writer ownership

The shared Supabase client boundary checks the target before constructing either client. This covers the API, escalation, SLA, planning, dispatch and storage cleanup jobs that import it. It also prevents signed-in local development from modifying the hosted production data through this backend. It is an accidental-configuration guard, not a credential or operating-system security boundary.

Routine development uses an isolated Supabase stack at `http://127.0.0.1:54321`, with that stack's own keys, Auth users/sessions and Storage buckets. Copy `.env.example` into an ignored `.env` only after the local stack exists and replace its key placeholders with local credentials. Use synthetic fixtures; never copy production users, sessions, images or service keys. The same bucket names in a different project refer to isolated storage.

An existing hosted development project is allowed only when `SUPABASE_URL` and `DEVELOPMENT_SUPABASE_URL` designate the same HTTPS origin. The known production origin is refused even when put on this development allowlist. Missing or malformed targets fail closed. There is no local production-write bypass.

Production startup requires both `NODE_ENV=production` and `DEPLOYMENT_ENV=production`. The existing deploy script supplies NODE_ENV; explicitly configure DEPLOYMENT_ENV on the production host as part of T15 preparation before deploying this candidate. This change has not been applied to the running host. Treat production settings and keys as host-owned configuration, not a local example to copy. A newly created production project/custom origin requires reviewing the guard's recorded production identity.

The currently running original localhost backend predates this guard and supplies production escalation coverage. The recovery candidate is a separate checkout. Do not restart, stop or reconfigure that existing process merely to adopt this guard; T11 prepares and T15 verifies a successful production scheduler handover before retiring the accounted-for local writer. The guard is effective when the candidate is used; it does not retrofit an already running process or protect separate scripts/mobile/web clients that bypass the backend.

Tests: `npm test -- --runInBand --runTestsByPath tests/development-isolation.test.js`. The tests deny production before client construction; they do not contact production. Real database, role/session and Storage integration requires the T02 development environment and synthetic fixtures to be running. A placeholder URL or mocked database is not proof of that setup.

## Local platform and synthetic fixtures

The checked-in `supabase/config.toml` initializes a separate project named `parity-recovery-backend` (Postgres 17). CLI initialization does not link it to the hosted project. The verified local setup uses Supabase CLI 2.122.0 and Docker on Windows. Keep that version for this setup; migration to CLI 3 is separate work.

```powershell
docker network create --driver bridge --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 ecopin-parity-local
supabase start --network-id ecopin-parity-local --exclude studio,postgres-meta,imgproxy,edge-runtime,logflare,vector,supavisor
node scripts/bind-local-parity.mjs
docker restart supabase_auth_parity-recovery-backend supabase_rest_parity-recovery-backend supabase_storage_parity-recovery-backend supabase_realtime_parity-recovery-backend
```

Create the network once; reuse it on later starts. Run from this checkout with the existing Supabase CLI executable or an equivalent pinned installation. Use `supabase status --output json` privately to configure the ignored `.env` with this stack's API URL, service/publishable keys and a fresh backend JWT secret. Keep the original backend's port 4002 free; use port 4102 for the recovery API. Local Auth's redirect origin is `http://127.0.0.1:3000`; use that host for the development web session. Direct email to local Mailpit, not a real SMTP account. Keep escalation disabled in the candidate until exercising synthetic development fixtures.

On the verified Windows Docker Desktop setup, the network's default binding option still produced wildcard published ports. The binding repair script validates exact project/workdir ownership before recreating only the three published local containers with `127.0.0.1`, preserving their configuration, writable files, aliases and named volumes. It restores the original container if replacement fails and verifies actual bindings and healthy startup before removing the replaced container without its volumes. Local `ecopin-parity-loopback` images retain generated certificates/configuration; keep them local and never push them. It is specific to the verified Windows engine; rerunning is a no-op once bindings are correct. Recheck bindings after CLI recreations. Do not run fixture seeding until the bindings are verified. Other platforms should use explicit loopback bindings through their own supported runtime configuration.

After a database container replacement, the consumer restart above discards connections to the old container. Wait for the local services to become healthy before seeding. This step affects only this disposable project's consumers, not the original backend on port 4002.

Run `node scripts/seed-local-parity.mjs` after setting the local keys. It refuses any target other than `http://127.0.0.1:54321`, creates five clearly synthetic Auth users, and writes one synthetic PNG into a private fixture bucket. It verifies local sign-in, service-side byte round trip and anonymous byte denial. Credentials and account IDs are saved only in ignored `.private/parity-fixtures.json`. Rerunning rotates only the fixture accounts' passwords and replaces only the fixture image; accounts with a different fixture marker are refused.

This establishes the real isolated platform, identities and sample media. It does not replay root `migrations/`, copy production records or claim that application workflow fixtures are complete. T03 must review the application catalog/baseline, apply the necessary prerequisites locally, and map fixture actors to authoritative application profiles before role-aware feature acceptance. Metadata labels on these Auth fixtures do not establish application authorization.

Use `supabase stop` from this checkout to stop only this local project when it is no longer needed. Do not use reset, volume deletion or `--no-backup` as a routine stop command.
