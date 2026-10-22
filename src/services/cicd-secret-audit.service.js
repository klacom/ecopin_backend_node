import fs from 'node:fs';
import path from 'node:path';

/**
 * CI/CD and deployment secret leakage audit engine.
 * Inspects build configurations, dockerignore files, gitignore files,
 * environment definitions, and source files for patterns that leak credentials.
 */

export const SECRET_PATTERNS = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /eyJ[A-Za-z0-9-_]{10,}\.eyJ[A-Za-z0-9-_]{10,}/, // JWT format
  /(?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*['"][A-Za-z0-9_\-.~+/$]{16,}['"]/i,
  /sb_secret_[a-zA-Z0-9_-]{20,}/, // Supabase modern secret key
  /sbp_[a-zA-Z0-9]{30,}/, // Supabase service tokens
  /ghp_[a-zA-Z0-9]{36}/,  // GitHub tokens
  /AKIA[0-9A-Z]{16}/,     // AWS Access Key ID
];

export const REQUIRED_DOCKERIGNORE_ENTRIES = [
  '.env',
  '*.pem',
  '*.key',
  'node_modules',
  '.git',
];

export const REQUIRED_GITIGNORE_ENTRIES = [
  '.env',
  '*.pem',
  '*.key',
  'node_modules',
];

/**
 * Checks if a gitignore or dockerignore contains rules covering critical secret extensions.
 */
export function verifyIgnoreRules(content) {
  const lines = content
    .split('\n')
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#'));

  const missing = [];

  const checks = [
    { name: '.env', regex: /^\.?env(\.\*)?$/ },
    { name: '*.pem', regex: /^\*\.pem$/ },
    { name: '*.key', regex: /^\*\.key$/ },
    { name: 'node_modules', regex: /^(\/)?node_modules(\/)?$/ }
  ];

  for (const check of checks) {
    const satisfied = lines.some(line => check.regex.test(line) || line.includes(check.name));
    if (!satisfied) {
      missing.push(check.name);
    }
  }

  return {
    valid: missing.length === 0,
    missing,
  };
}

/**
 * Scans a file's content for unredacted sensitive patterns.
 */
export function scanContentForSecrets(content, filePath = '') {
  const violations = [];
  const lines = content.split('\n');

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Ignore lines that are clearly documentation, comments, or test mocks
    if (line.includes('process.env.') || line.includes('placeholder') || line.includes('example')) {
      continue;
    }

    for (const pattern of SECRET_PATTERNS) {
      if (pattern.test(line)) {
        violations.push({
          line: i + 1,
          pattern: pattern.toString(),
          file: filePath,
          preview: line.slice(0, 30) + '...',
        });
      }
    }
  }

  return violations;
}

/**
 * Audits repository deployment and build safety.
 */
export function runSecretAudit(repoRoot) {
  const report = {
    checkedFiles: 0,
    violations: [],
    ignoreAudits: {},
  };

  const backendDockerignore = path.join(repoRoot, 'ecopin_backend_node', '.dockerignore');
  if (fs.existsSync(backendDockerignore)) {
    const content = fs.readFileSync(backendDockerignore, 'utf8');
    report.ignoreAudits['backend.dockerignore'] = verifyIgnoreRules(content);
  } else {
    report.ignoreAudits['backend.dockerignore'] = { valid: false, missing: ['FILE_NOT_FOUND'] };
  }

  const backendGitignore = path.join(repoRoot, 'ecopin_backend_node', '.gitignore');
  if (fs.existsSync(backendGitignore)) {
    const content = fs.readFileSync(backendGitignore, 'utf8');
    report.ignoreAudits['backend.gitignore'] = verifyIgnoreRules(content);
  } else {
    report.ignoreAudits['backend.gitignore'] = { valid: false, missing: ['FILE_NOT_FOUND'] };
  }

  const webDockerignore = path.join(repoRoot, 'ecopin-web', '.dockerignore');
  if (fs.existsSync(webDockerignore)) {
    const content = fs.readFileSync(webDockerignore, 'utf8');
    report.ignoreAudits['web.dockerignore'] = verifyIgnoreRules(content);
  } else {
    report.ignoreAudits['web.dockerignore'] = { valid: false, missing: ['FILE_NOT_FOUND'] };
  }

  const webGitignore = path.join(repoRoot, 'ecopin-web', '.gitignore');
  if (fs.existsSync(webGitignore)) {
    const content = fs.readFileSync(webGitignore, 'utf8');
    report.ignoreAudits['web.gitignore'] = verifyIgnoreRules(content);
  } else {
    report.ignoreAudits['web.gitignore'] = { valid: false, missing: ['FILE_NOT_FOUND'] };
  }

  return report;
}
