# Production deployment

Backend production follows `master` in `klacom/ecopin_backend_node`. The dashboard stays on Vercel.
GitHub Actions runs syntax checks, tests and the production dependency audit, packages source plus Linux dependencies and Node 24, then uploads a SHA-addressed release to S3. A fixed SSM command switches the PM2 service on the existing EC2 instance. Nginx and port 3002 remain in place. A failing `/health` restores the previous release and fails the workflow.

ML production follows `main` in `klacom/ecopin_ml_models`; its workflow owns the three existing Lambda images. Deploy ML before the first backend release because the backend health check requires the Exp 3.2 classifier. See that repository's `DEPLOY.md`.

## One-time AWS access changes

Review and run `scripts/deploy/bootstrap.ps1` using an AWS administrator session in account `035074951255`, region `ap-southeast-1`. It creates:

- GitHub OIDC provider `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
- Role `ecopin-backend-github-deploy`: trust only this repo's `master`; write only the deployment bucket's `backend/` objects; invoke only `EcoPin-DeployBackend` against instance `i-09848ea939a21db3c`. SSM result reads require wildcard resource because that API has no resource-level scope.
- Role `ecopin-ml-github-deploy`: trust only the ML repo's `main`; push/read only `clip-validation-lambda`, `ecopin-vrp-service`, `hotspot-forecasting` ECR repositories; read/update/invoke only the three existing functions. Registry login requires a wildcard resource.
- Both trust policies pin the verified GitHub owner/repository IDs as well as branch names, matching this account's actual OIDC subjects. The ML role also allows public ECR authentication (including a service-limited STS bearer token) to avoid anonymous base-image pull quotas; it gains no additional private-repository access.
- Private, versioned, AES256-encrypted bucket `ecopin-deploy-035074951255-ap-southeast-1`; public access blocked and HTTPS enforced. It stores deployment artifacts, never `.env` files.
- SSM document `EcoPin-DeployBackend`: accepts only a 40-character hex release SHA and calls a root-owned fixed script as `ubuntu`.
- Instance role/profile `ecopin-backend-instance`: SSM managed-node permissions plus read-only access to backend artifacts. The profile is attached to the existing backend instance only if it has no profile.

These roles grant production code execution through deployments. Protect write access to the two production branches. The bootstrap does not delete or replace EC2, Lambda, databases or existing ECR repositories. It does not install an AWS access key in GitHub. It updates the named deployment roles on reruns; those names must remain dedicated to this setup.

Upload `setup-host.sh` and `deploy-backend.sh` to EC2, then run the former with sudo and the latter's path. Setup installs AWS CLI and required system libraries, protects/backups the existing environment, installs the root-owned deployment script, and restarts SSM Agent. It does not restart the backend.

Keep production environment values on EC2, not in the repository or workflow. Verify current Supabase URL/keys, strong `JWT_SECRET`, frontend origin and all three AWS endpoint settings before the first release. Existing production settings point to old database/service configuration and must be reconciled with the working local setup. Never print environment values during setup.

## Release and rollback

Push to `master`, or run **Backend production** manually on `master`. PRs run checks without AWS access. GitHub serializes deployments and does not cancel a deployment midway.

Automatic rollback uses the currently running release (the original checkout for the first deployment). For manual rollback, SSH to EC2 and run as `ubuntu`:

```bash
readlink /home/ubuntu/ecopin-deploy/previous
/opt/ecopin/deploy-backend.sh <previous-40-character-commit-sha>
```

The first pre-CI/CD checkout has no release SHA; restoring it requires starting its `src/index.js` with PM2 from `/home/ubuntu/ecopin_backend_node`. Environment rollback is separate: restore the protected `.private/pre-cicd.env` backup if necessary. Database migrations are not applied automatically; review them separately because code rollback cannot undo database changes.

Release folders and S3 artifacts consume storage. Remove old releases only after confirming they are neither `current` nor `previous`; retain known-good rollback images in ECR. The EC2 public IP is not an Elastic IP and can change after stop/start. Existing backend HTTP has no TLS; adding HTTPS/custom domain is a separate infrastructure change.

## Verification status

Local backend tests passed (186 tests) after the dependency lockfile and classifier health check updates. Production dependency audit has no high/critical findings; moderate transitive findings remain. Bootstrap has a mocked contract check (`scripts/deploy/test-bootstrap.ps1`) that makes no AWS calls. Real Linux builds, SSM deployment, production environment reconciliation and live health checks still need execution; local Docker Desktop is unavailable.
