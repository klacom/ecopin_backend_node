#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
release=${1:?release SHA required}
[[ "$release" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid release SHA'; exit 2; }
root=/home/ubuntu/ecopin-deploy
bucket=ecopin-deploy-035074951255-ap-southeast-1
mkdir -p "$root/releases"
exec 9>"$root/deploy.lock"
flock -n 9 || { echo 'Another deployment is running'; exit 1; }
if [[ -L "$root/current" && -f "$root/current/src/index.js" ]]; then
  previous=$(readlink -f "$root/current")
else
  previous=/home/ubuntu/ecopin_backend_node
fi
target="$root/releases/$release"
# Existing releases are immutable and can be selected again for rollback.
if [[ ! -f "$target/.complete" ]]; then
  stage=$(mktemp -d "$root/releases/.stage.XXXXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  aws s3 cp "s3://$bucket/backend/$release.tar.gz" "$stage/release.tar.gz" --only-show-errors
  aws s3 cp "s3://$bucket/backend/$release.sha256" "$stage/release.sha256" --only-show-errors
  (cd "$stage"; sha256sum -c release.sha256)
  mkdir "$stage/app"
  tar -xzf "$stage/release.tar.gz" -C "$stage/app"
  [[ -x "$stage/app/runtime/node" && -f "$stage/app/src/index.js" ]]
  touch "$stage/app/.complete"
  # A failed earlier installation may have left this SHA's directory behind.
  [[ ! -e "$target" ]] || { echo 'Incomplete existing release; inspect it manually'; exit 1; }
  mv "$stage/app" "$target"
fi
ln -sfn /home/ubuntu/ecopin_backend_node/.env "$target/.env"
ln -sfn /home/ubuntu/ecopin_backend_node/.private "$target/.private"
start_release() {
  local directory=$1
  local interpreter="$directory/runtime/node"
  [[ -x "$interpreter" ]] || interpreter=$(command -v node)
  pm2 delete backend >/dev/null 2>&1 || true
  (cd "$directory"; NODE_ENV=production PORT=3002 pm2 start src/index.js --name backend \
    --interpreter "$interpreter" --max-memory-restart 350M --time >/dev/null)
}
healthy() {
  for attempt in $(seq 1 24); do
    if curl --fail --silent --max-time 10 http://127.0.0.1:3002/health >"$root/health.json"; then return 0; fi
    sleep 5
  done
  return 1
}
# "Healthy" only says that something answered. The selected release must also be the one that answers, the one pm2 runs, and the one current will name.
# Older immutable releases that predate the RELEASE file are identified by their directory (named by SHA) and the running process only.
identity_ok() {
  "$target/runtime/node" - "$release" "$target" "$root/health.json" <<'NODE'
const { readFileSync, existsSync, realpathSync } = require('node:fs');
const { execFileSync } = require('node:child_process');
const [release, target, healthFile] = process.argv.slice(2);
const fail = message => { console.error('Release identity check failed: ' + message); process.exit(1); };
let health;
try { health = JSON.parse(readFileSync(healthFile, 'utf8')); } catch { fail('the health response is not JSON'); }
const reported = health?.release?.sha ?? null;
if (reported !== release) {
  if (reported === null && !existsSync(target + '/RELEASE')) console.log('Legacy artifact without a RELEASE file: identity taken from its directory and process only');
  else fail('health reports release ' + (reported ?? 'none') + ' (' + (health?.release?.source ?? 'unknown') + '), selected ' + release);
}
let processes;
try { processes = JSON.parse(execFileSync('pm2', ['jlist'], { encoding: 'utf8', shell: process.platform === 'win32' })); } catch { fail('the process list cannot be read'); }
const backend = processes.find(entry => entry.name === 'backend');
if (!backend || backend.pm2_env?.status !== 'online') fail('the backend process is not online');
const real = path => { try { return realpathSync(path); } catch { return path; } };
if (real(backend.pm2_env.pm_cwd) !== real(target)) fail('the process runs from ' + backend.pm2_env.pm_cwd + ', selected ' + target);
console.log('Release identity verified: health, process directory and selection agree');
NODE
}
rollback() {
  trap - ERR
  echo "Deployment failed; restoring $previous"
  start_release "$previous"
  if healthy; then echo 'Previous release restored'; else echo 'Previous release also fails health checks'; fi
  ln -sfn "$previous" "$root/current"
  pm2 save >/dev/null
  exit 1
}
trap rollback ERR
start_release "$target"
healthy
identity_ok
ln -sfn "$previous" "$root/previous"
ln -sfn "$target" "$root/current"
[[ "$(readlink -f "$root/current")" == "$(readlink -f "$target")" ]] || { echo 'current does not name the selected release'; false; }
pm2 save >/dev/null
trap - ERR
echo "Healthy backend release: $release"
