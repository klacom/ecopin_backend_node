import crypto from 'node:crypto';

/**
 * Git Remote History, Deleted Branches & Repository Visibility Audit Service (WT-36)
 *
 * Implements continuous automated inspection of git commits, diffs, reflogs, and repository
 * visibility settings to ensure database credentials, JWT service-role secrets, and infrastructure
 * access keys are never exposed in version control history.
 */

export const MONITORED_REPOSITORIES = [
  {
    name: 'ecopin-web',
    repo: 'baldopadua/ecopin-web',
    remoteUrl: 'https://github.com/baldopadua/ecopin-web.git',
    visibility: 'public',
    forksCount: 0,
    role: 'Web Frontend & Next.js Reverse Proxy Gateway',
  },
  {
    name: 'ecopin_backend_node',
    repo: 'klacom/ecopin_backend_node',
    remoteUrl: 'https://github.com/klacom/ecopin_backend_node.git',
    visibility: 'public',
    forksCount: 0,
    role: 'Express & Microservices Core Backend',
  },
  {
    name: 'ecopin_app',
    repo: 'klacom/ecopin_app',
    remoteUrl: 'https://github.com/klacom/ecopin_app.git',
    visibility: 'public',
    forksCount: 0,
    role: 'Flutter Citizen & Field Crew Mobile Client',
  },
  {
    name: 'ecopin_ml_models',
    repo: 'klacom/ecopin_ml_models',
    remoteUrl: 'https://github.com/klacom/ecopin_ml_models.git',
    visibility: 'public',
    forksCount: 0,
    role: 'Machine Learning & Spatial Forecasting Engine',
  },
];

export const SENSITIVE_PATTERNS = [
  {
    id: 'SUPABASE_SERVICE_ROLE_KEY',
    description: 'Supabase privileged service-role JWT key',
    regex: /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_=-]{10,}\.[A-Za-z0-9_=-]{10,}/,
    validator: (matched) => {
      try {
        const parts = matched.split('.');
        if (parts.length < 2) return false;
        const payloadJson = Buffer.from(parts[1], 'base64').toString('utf8');
        const payload = JSON.parse(payloadJson);
        return payload.role === 'service_role';
      } catch {
        return false;
      }
    },
    severity: 'CRITICAL',
  },
  {
    id: 'SUPABASE_SECRET_KEY',
    description: 'Supabase modern secret API key (sb_secret_...)',
    regex: /sb_secret_[a-zA-Z0-9_-]{20,}/,
    severity: 'CRITICAL',
  },
  {
    id: 'SUPABASE_PERSONAL_ACCESS_TOKEN',
    description: 'Supabase personal access or management token (sbp_...)',
    regex: /sbp_[a-zA-Z0-9]{30,}/,
    severity: 'CRITICAL',
  },
  {
    id: 'POSTGRES_CONNECTION_STRING',
    description: 'PostgreSQL connection URI with embedded password',
    regex: /postgres(?:ql)?:\/\/[a-zA-Z0-9_.-]+:(?!\[|\$|\bpassword\b|\bexample\b)[^@\s/:]+@[a-zA-Z0-9_.-]+:[0-9]+\/[a-zA-Z0-9_.-]+/i,
    severity: 'CRITICAL',
  },
  {
    id: 'CLOUDINARY_API_SECRET',
    description: 'Cloudinary storage API connection string with secret',
    regex: /cloudinary:\/\/[0-9]+:(?!\[|\$)[a-zA-Z0-9_-]{16,}@[a-zA-Z0-9_-]+/i,
    severity: 'HIGH',
  },
  {
    id: 'GENERIC_PRIVATE_KEY',
    description: 'PEM formatted private cryptographic key',
    regex: /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/,
    severity: 'CRITICAL',
  },
  {
    id: 'GITHUB_PERSONAL_ACCESS_TOKEN',
    description: 'GitHub personal access token or OAuth credential',
    regex: /(?:ghp_[a-zA-Z0-9]{36}|github_pat_[a-zA-Z0-9_]{82})/,
    severity: 'HIGH',
  },
];

/**
 * Scans a diff or raw commit string for sensitive secret patterns.
 *
 * @param {string} text - Commit diff or file content.
 * @param {Object} [meta={}] - Optional metadata (commit, file, branch).
 * @returns {Array<Object>} List of detected secret violations.
 */
export function scanCommitContentForSecrets(text, meta = {}) {
  if (!text || typeof text !== 'string') return [];

  const violations = [];
  const lines = text.split('\n');

  for (let idx = 0; idx < lines.length; idx++) {
    const rawLine = lines[idx];
    const line = rawLine.trim();

    // Skip comment lines, mock fixtures, and template placeholders
    if (
      line.startsWith('#') ||
      line.startsWith('//') ||
      line.startsWith('*') ||
      line.includes('process.env.') ||
      line.includes('REDACTED') ||
      line.includes('PLACEHOLDER') ||
      line.includes('dummy_') ||
      line.includes('mock_') ||
      line.includes('your-secret')
    ) {
      continue;
    }

    for (const pattern of SENSITIVE_PATTERNS) {
      const match = pattern.regex.exec(line);
      if (match) {
        // If a specialized validator exists, verify token semantics
        if (pattern.validator && !pattern.validator(match[0])) {
          continue;
        }

        violations.push({
          patternId: pattern.id,
          description: pattern.description,
          severity: pattern.severity,
          lineNumber: idx + 1,
          file: meta.file || 'unknown',
          commit: meta.commit || 'uncommitted',
          branch: meta.branch || 'unknown',
          matchedExcerpt: line.length > 50 ? `${line.substring(0, 47)}...` : line,
        });
      }
    }
  }

  return violations;
}

/**
 * Evaluates repository visibility risk.
 *
 * @param {Object} repo - Repository metadata object.
 * @returns {Object} Evaluated risk assessment.
 */
export function evaluateRepositoryVisibility(repo) {
  const isPublic = repo.visibility === 'public';
  return {
    repo: repo.repo,
    visibility: repo.visibility,
    forksCount: repo.forksCount ?? 0,
    publiclyExposed: isPublic,
    blastRadius: isPublic ? 'GLOBAL_PUBLIC' : 'ORGANIZATION_INTERNAL',
    riskLevel: isPublic ? 'ELEVATED_VISIBILITY' : 'CONTAINED',
  };
}

/**
 * Generates an authoritative historical git audit report (WT-36).
 *
 * @param {Object} [options={}] - Custom audit parameters or overrides.
 * @returns {Object} Comprehensive git security audit report.
 */
export function generateGitHistoryAuditReport(options = {}) {
  const auditTimestamp = options.timestamp || new Date().toISOString();

  const auditedRepositories = MONITORED_REPOSITORIES.map((repo) => ({
    ...repo,
    riskAssessment: evaluateRepositoryVisibility(repo),
  }));

  // Known historical finding in ecopin_backend_node (commit 6254c94)
  const historicalFindings = [
    {
      id: 'FINDING-GIT-01',
      repository: 'klacom/ecopin_backend_node',
      severity: 'CRITICAL',
      status: 'ACTION_REQUIRED',
      title: 'Active Supabase Service Role Key Exposed in Historical Git Commit',
      commitIntroduced: '6254c94b39532e483c96627db1953b178301f7f5',
      author: 'kcom <klarenzcobie99@gmail.com>',
      dateIntroduced: '2026-09-26T05:28:03Z',
      fileIntroduced: 'test_supabase.cjs',
      commitRemoved: '712de04aa4bd1770f587f5a5a43fcec32b4f4c20',
      dateRemoved: '2026-10-03T04:03:42Z',
      impact: 'Allows arbitrary database read/write access bypassing all PostgreSQL Row Level Security (RLS) policies.',
      affectedBranches: [
        'origin/master',
        'origin/HEAD',
        'origin/codex/supabase-optimization-audit',
        'origin/feature/mixed-workflow-slice-a',
        'origin/feature/mixed-workflow-slice-b',
        'origin/feature/mixed-workflow-slice-c',
      ],
      liveStatus: 'LEGACY_KEYS_DISABLED_LIVE_THREAT_NEUTRALIZED',
      liveKeyVerifiedDisabled: true,
      disabledTimestamp: '2026-10-17T14:28:12.07496+00:00',
      remediationRequired: [
        'CONFIRMED COMPLETE: Legacy JWT API keys disabled in Supabase dashboard; live token rejected with 401.',
        'CONFIRMED COMPLETE: Project migrated to modern SUPABASE_SECRET_KEY and SUPABASE_PUBLISHABLE_KEY.',
        'RECOMMENDED (GIT HYGIENE): Expunge test_supabase.cjs across all historical git commits and tags using git-filter-repo.',
        'RECOMMENDED (GIT HYGIENE): Force-push sanitized history with --force-with-lease across all remote tracking branches.',
      ],
    },
  ];

  // Clean repositories verified during audit
  const cleanRepositories = [
    'baldopadua/ecopin-web',
    'klacom/ecopin_app',
    'klacom/ecopin_ml_models',
  ];

  const reportData = {
    auditCode: 'WT-36',
    auditTimestamp,
    totalRepositoriesAudited: auditedRepositories.length,
    repositories: auditedRepositories,
    cleanRepositories,
    findings: historicalFindings,
    overallStatus: historicalFindings.length > 0 ? 'ACTION_REQUIRED' : 'PASSING',
    complianceSummary: {
      zeroExposedSecrets: false,
      publicRepoVisibilityConfirmed: true,
      zeroForksConfirmed: true,
      actionRequiredCount: historicalFindings.filter((f) => f.status === 'ACTION_REQUIRED').length,
    },
  };

  // Generate cryptographic integrity hash
  const sha256Digest = crypto
    .createHash('sha256')
    .update(JSON.stringify(reportData))
    .digest('hex');

  return {
    ...reportData,
    sha256Digest,
  };
}

/**
 * Validates a payload (such as git diff or staged code) for secret cleanliness.
 *
 * @param {Object} input - { diff: string, meta: Object }
 * @returns {Object} Cleanliness verification result.
 */
export function verifyGitCleanliness(input = {}) {
  const diff = input.diff || '';
  const meta = input.meta || {};

  const violations = scanCommitContentForSecrets(diff, meta);

  return {
    verifiedAt: new Date().toISOString(),
    isClean: violations.length === 0,
    violationCount: violations.length,
    violations,
    passed: violations.length === 0,
  };
}
