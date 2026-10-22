#!/usr/bin/env node

/**
 * CI/CD Secret Audit CLI Runner
 * Runs during build and pre-deployment checks to confirm no secrets, keys, or private files are exposed.
 */

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runSecretAudit } from '../src/services/cicd-secret-audit.service.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '../..');

console.log('[CI/CD Secret Audit] Starting security audit of deployment configurations...');

const report = runSecretAudit(repoRoot);

let hasErrors = false;
for (const [target, result] of Object.entries(report.ignoreAudits)) {
  if (!result.valid) {
    console.error(`[FAIL] ${target} is missing required protection rules: ${result.missing.join(', ')}`);
    hasErrors = true;
  } else {
    console.log(`[PASS] ${target} complies with secret isolation standards.`);
  }
}

if (hasErrors) {
  console.error('\n[CI/CD Secret Audit] FAILURE: Sensitive file exposure risks detected.');
  process.exit(1);
} else {
  console.log('\n[CI/CD Secret Audit] SUCCESS: All deployment pipelines and build containers are safeguarded against secret leakage.');
  process.exit(0);
}
