import assert from 'node:assert/strict';
import http from 'node:http';
import {execFileSync} from 'node:child_process';

// Docker Desktop's Windows forwarder did not honor this network's default bind address.
// Recreate only these owned local containers with explicit bindings; retain their volumes.
const project = 'parity-recovery-backend';
const names = ['db', 'kong', 'inbucket'].map(service => `supabase_${service}_${project}`);
const endpoint = execFileSync('docker', ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], {encoding: 'utf8'}).trim();
assert.equal(endpoint, 'npipe:////./pipe/dockerDesktopLinuxEngine', 'This repair is specific to the verified local Windows engine.');
const socketPath = '\\\\.\\pipe\\dockerDesktopLinuxEngine';
function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : JSON.stringify(body);
    const req = http.request({socketPath, method, path: `/v1.51${path}`, headers: data ? {'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data)} : {}}, res => {
      let result = '';
      res.on('data', chunk => { result += chunk; });
      res.on('end', () => {
        if (res.statusCode >= 300) return reject(new Error(`Local Docker request failed (${res.statusCode}); inspect local container state.`));
        resolve(result ? JSON.parse(result) : undefined);
      });
    });
    req.setTimeout(60000, () => req.destroy(new Error('Local Docker request timed out.')));
    req.on('error', reject);
    req.end(data);
  });
}
const containers = JSON.parse(execFileSync('docker', ['inspect', ...names], {encoding: 'utf8'}));
for (const container of containers) {
  assert.equal(container.Config.Labels['com.supabase.cli.project'], project);
  assert.equal(container.Config.Labels['com.supabase.cli.workdir'].replaceAll('\\', '/'), process.cwd().replaceAll('\\', '/'));
  assert.equal(Object.keys(container.NetworkSettings.Networks).join(), 'ecopin-parity-local');
  const bindings = Object.values(container.HostConfig.PortBindings).flat();
  assert.ok(bindings.length && bindings.every(binding => ['54321', '54322', '54324'].includes(binding.HostPort)));
}
for (const container of containers) {
  const name = container.Name.slice(1);
  if (Object.values(container.HostConfig.PortBindings).flat().every(binding => binding.HostIp === '127.0.0.1')) {
    assert.ok(container.State.Running && container.State.Health?.Status !== 'unhealthy', 'Local container needs recovery before binding verification.');
    continue;
  }
  // CLI-generated certificates/configuration can live in the writable layer, not a volume.
  // Keep this local image private; it includes this disposable stack's configuration.
  const snapshot = await request('POST', `/commit?container=${container.Id}&pause=true&repo=ecopin-parity-loopback&tag=${name}`);
  const body = {...container.Config, HostConfig: container.HostConfig, NetworkingConfig: {EndpointsConfig: {
    'ecopin-parity-local': {Aliases: container.NetworkSettings.Networks['ecopin-parity-local'].Aliases}
  }}, Image: snapshot.Id};
  for (const binding of Object.values(body.HostConfig.PortBindings).flat()) binding.HostIp = '127.0.0.1';
  await request('POST', `/containers/${container.Id}/stop?t=30`);
  await request('POST', `/containers/${container.Id}/rename?name=${name}-binding-backup`);
  let created;
  try {
    created = await request('POST', `/containers/create?name=${name}`, body);
    await request('POST', `/containers/${created.Id}/start`);
    let verified;
    for (let attempt = 0; attempt < 45; attempt++) {
      verified = await request('GET', `/containers/${created.Id}/json`);
      if (verified.State.Running && (!verified.State.Health || verified.State.Health.Status === 'healthy')) break;
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    assert.ok(verified.State.Running && (!verified.State.Health || verified.State.Health.Status === 'healthy'), 'Replacement did not become healthy.');
    assert.ok(Object.values(verified.NetworkSettings.Ports).filter(Boolean).flat().every(binding => binding.HostIp === '127.0.0.1'));
  } catch (error) {
    // Preserve a failed replacement for inspection and put the original container back.
    if (created) {
      await request('POST', `/containers/${created.Id}/stop?t=5`).catch(() => {});
      await request('POST', `/containers/${created.Id}/rename?name=${name}-binding-failed`);
    }
    await request('POST', `/containers/${container.Id}/rename?name=${name}`);
    await request('POST', `/containers/${container.Id}/start`);
    throw error;
  }
  // Remove the replaced container only, never its retained named volumes.
  await request('DELETE', `/containers/${container.Id}`);
  console.log(`${name}: explicit loopback binding verified; data volumes retained`);
}
