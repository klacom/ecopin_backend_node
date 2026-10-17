import crypto from 'node:crypto';

/**
 * EcoPin Staging & Preview Deployment Environment Audit Service (WT-42)
 *
 * Requirements:
 * 1. Confirm preview/staging URLs require authentication (deployment protection / access gate).
 * 2. Confirm preview/staging environments lack debug bypasses (flags, backdoor headers, test pages).
 * 3. Confirm preview/staging environments do NOT connect to production databases.
 * 4. Confirm preview/staging environments do NOT connect to live citizen storage buckets.
 */

export const PRODUCTION_DOMAINS = ['app.ecopin.ph', 'api.ecopin.ph'];

export const PREVIEW_DOMAIN_REGEXES = [
  /\.vercel\.app$/i,
  /^staging\.ecopin\.ph$/i,
  /^preview-[a-z0-9-]+\.ecopin\.ph$/i,
  /^qa\.ecopin\.ph$/i,
  /^dev\.ecopin\.ph$/i
];

export const LIVE_CITIZEN_STORAGE_BUCKETS = [
  'report-evidence',
  'cleanup-task-photos',
  'report-cleanup'
];

export const FORBIDDEN_DEBUG_FLAGS = [
  'BYPASS_AUTH',
  'DEBUG_AUTH',
  'SKIP_AUTH',
  'MOCK_AUTH',
  'DISABLE_RATE_LIMITS',
  'DISABLE_CSRF',
  'ALLOW_INSECURE_DEBUG',
  'ENABLE_TEST_SESSION_PAGE'
];

export const FORBIDDEN_DEBUG_HEADERS = [
  'x-debug-bypass',
  'x-bypass-auth',
  'x-admin-impersonate',
  'x-test-bypass',
  'x-ecopin-mock-role'
];

/**
 * Identifies whether a given hostname is a preview or staging domain.
 */
export function isPreviewOrStagingDomain(hostname = '') {
  if (!hostname || typeof hostname !== 'string') return false;
  const clean = hostname.toLowerCase().trim().split(':')[0];

  if (PRODUCTION_DOMAINS.includes(clean)) {
    return false;
  }

  return PREVIEW_DOMAIN_REGEXES.some(regex => regex.test(clean));
}

/**
 * Checks whether an environment configuration enforces authentication on preview/staging URLs.
 */
export function evaluatePreviewAccessControl(envConfig = {}) {
  const isPreviewOrStaging =
    envConfig.ENVIRONMENT === 'staging' ||
    envConfig.ENVIRONMENT === 'preview' ||
    envConfig.NODE_ENV === 'staging' ||
    envConfig.VERCEL_ENV === 'preview' ||
    isPreviewOrStagingDomain(envConfig.HOST_DOMAIN || envConfig.FRONTEND_URL);

  if (!isPreviewOrStaging) {
    return {
      applicable: false,
      status: 'NOT_APPLICABLE',
      details: 'Environment is production or local development'
    };
  }

  // Preview authentication must be explicitly active via Vercel Deployment Protection,
  // SSO access gateway, or preview HTTP Basic Auth.
  const hasVercelProtection = envConfig.VERCEL_PROTECTION_ENABLED === 'true' || envConfig.VERCEL_ENV_PROTECTED === '1';
  const hasGatewayAuth = envConfig.PREVIEW_AUTH_ENABLED === 'true' || envConfig.STAGING_AUTH_REQUIRED === 'true';
  const hasBasicAuth = Boolean(envConfig.PREVIEW_BASIC_AUTH_SECRET || envConfig.ACCESS_GATEWAY_TOKEN);

  const isProtected = hasVercelProtection || hasGatewayAuth || hasBasicAuth;

  return {
    applicable: true,
    protected: isProtected,
    mechanism: hasVercelProtection
      ? 'Vercel Deployment Protection'
      : hasGatewayAuth
      ? 'Edge Access Gateway SSO'
      : hasBasicAuth
      ? 'Preview HTTP Basic Auth'
      : 'NONE',
    status: isProtected ? 'PASSED' : 'VIOLATION',
    message: isProtected
      ? 'Preview/staging deployment enforces authentication gateway'
      : 'VIOLATION: Preview/staging deployment allows unauthenticated public access'
  };
}

/**
 * Audits environment configurations for active debug bypasses or backdoor flags.
 */
export function evaluateDebugBypasses(envConfig = {}) {
  const activeBypasses = [];

  for (const flag of FORBIDDEN_DEBUG_FLAGS) {
    const val = envConfig[flag];
    if (val === 'true' || val === '1' || val === true) {
      activeBypasses.push({
        flag,
        value: val,
        severity: 'CRITICAL',
        description: `Dangerous debug flag '${flag}' is enabled`
      });
    }
  }

  const bypassHeadersAllowed =
    envConfig.ALLOW_DEBUG_HEADERS === 'true' ||
    envConfig.TRUST_BYPASS_HEADERS === 'true' ||
    Boolean(envConfig.DEBUG_OVERRIDE_SECRET);

  if (bypassHeadersAllowed) {
    activeBypasses.push({
      flag: 'ALLOW_DEBUG_HEADERS',
      value: true,
      severity: 'CRITICAL',
      description: 'Server permits debug headers (x-debug-bypass / x-admin-impersonate)'
    });
  }

  return {
    clean: activeBypasses.length === 0,
    bypassesDetected: activeBypasses.length,
    activeBypasses,
    status: activeBypasses.length === 0 ? 'PASSED' : 'VIOLATION',
    message: activeBypasses.length === 0
      ? 'Zero debug bypasses or backdoor headers detected'
      : `VIOLATION: Found ${activeBypasses.length} active debug bypass(es)`
  };
}

/**
 * Audits database connection configuration ensuring non-production environments
 * do not cross over to the production PostgreSQL / Supabase database.
 */
export function evaluateDatabaseIsolation(envConfig = {}) {
  const environment = envConfig.ENVIRONMENT || envConfig.NODE_ENV || 'production';
  const isNonProd = environment === 'staging' || environment === 'preview' || environment === 'test';

  const dbUrl = envConfig.DATABASE_URL || envConfig.SUPABASE_DB_URL || '';
  const supabaseUrl = envConfig.SUPABASE_URL || envConfig.NEXT_PUBLIC_SUPABASE_URL || '';
  const prodDbHost = envConfig.PROD_DATABASE_HOST || 'db.ecopin.ph';
  const prodSupabaseProject = envConfig.PROD_SUPABASE_PROJECT_REF || 'supabase-prod-ecopin';

  let hasCrossover = false;
  const crossoverDetails = [];

  if (isNonProd) {
    // Check if dbUrl targets production host
    if (dbUrl && prodDbHost && dbUrl.includes(prodDbHost)) {
      hasCrossover = true;
      crossoverDetails.push(`DATABASE_URL targets production host: ${prodDbHost}`);
    }

    // Check if supabaseUrl targets production project ref
    if (supabaseUrl && prodSupabaseProject && supabaseUrl.includes(prodSupabaseProject)) {
      hasCrossover = true;
      crossoverDetails.push(`SUPABASE_URL targets production project ref: ${prodSupabaseProject}`);
    }
  }

  return {
    isolated: !hasCrossover,
    environment,
    status: !hasCrossover ? 'PASSED' : 'VIOLATION',
    crossoverDetails,
    message: !hasCrossover
      ? 'Database isolation verified: Staging/preview does not connect to production database'
      : 'CRITICAL VIOLATION: Staging/preview connects directly to production database!'
  };
}

/**
 * Audits storage bucket configuration ensuring non-production environments
 * do not read from or write to live citizen photo and evidence storage buckets.
 */
export function evaluateStorageBucketIsolation(envConfig = {}) {
  const environment = envConfig.ENVIRONMENT || envConfig.NODE_ENV || 'production';
  const isNonProd = environment === 'staging' || environment === 'preview' || environment === 'test';

  const configuredBuckets = [
    envConfig.STORAGE_BUCKET_REPORTS || envConfig.REPORT_EVIDENCE_BUCKET,
    envConfig.STORAGE_BUCKET_TASKS || envConfig.CLEANUP_TASK_BUCKET,
    envConfig.STORAGE_BUCKET_CLEANUP || envConfig.REPORT_CLEANUP_BUCKET
  ].filter(Boolean);

  let hasCrossover = false;
  const bucketViolations = [];

  if (isNonProd) {
    for (const bucket of configuredBuckets) {
      // If a non-prod environment uses exact live citizen bucket names without prefix/suffix
      if (LIVE_CITIZEN_STORAGE_BUCKETS.includes(bucket)) {
        hasCrossover = true;
        bucketViolations.push(`Bucket '${bucket}' matches live citizen production storage`);
      }
    }
  }

  return {
    isolated: !hasCrossover,
    environment,
    configuredBuckets,
    bucketViolations,
    status: !hasCrossover ? 'PASSED' : 'VIOLATION',
    message: !hasCrossover
      ? 'Storage bucket isolation verified: Live citizen storage buckets quarantined'
      : 'CRITICAL VIOLATION: Staging/preview configured with live citizen production storage buckets!'
  };
}

/**
 * Performs a comprehensive audit of a deployment environment.
 */
export function auditDeploymentEnvironment(envConfig = {}) {
  const accessControl = evaluatePreviewAccessControl(envConfig);
  const debugBypasses = evaluateDebugBypasses(envConfig);
  const dbIsolation = evaluateDatabaseIsolation(envConfig);
  const storageIsolation = evaluateStorageBucketIsolation(envConfig);

  const checks = [
    { name: 'Preview Access Control (Auth Gateway)', ...accessControl },
    { name: 'Debug & Backdoor Bypass Absence', ...debugBypasses },
    { name: 'Database Isolation (No Prod DB Crossover)', ...dbIsolation },
    { name: 'Storage Bucket Isolation (No Live Citizen Storage)', ...storageIsolation }
  ];

  const violations = checks.filter(c => c.status === 'VIOLATION');
  const isCompliant = violations.length === 0;

  const auditDigest = crypto
    .createHash('sha256')
    .update(JSON.stringify({ checks, isCompliant, timestamp: new Date().toISOString() }))
    .digest('hex');

  return {
    auditId: crypto.randomUUID(),
    timestamp: new Date().toISOString(),
    environment: envConfig.ENVIRONMENT || envConfig.NODE_ENV || 'production',
    isCompliant,
    outcome: isCompliant ? 'COMPLIANT' : 'NON_COMPLIANT',
    totalChecks: checks.length,
    passedChecks: checks.filter(c => c.status === 'PASSED').length,
    violationCount: violations.length,
    violations: violations.map(v => ({ check: v.name, message: v.message })),
    checks,
    auditDigest
  };
}

/**
 * Simulates preview access verification for automated tests and admin verification drills.
 */
export function simulatePreviewAccessVerification(requestContext = {}) {
  const {
    url = 'https://preview-deploy.ecopin.ph/dashboard',
    headers = {},
    hasDeploymentAuth = false
  } = requestContext;

  const urlObj = new URL(url);
  const isPreview = isPreviewOrStagingDomain(urlObj.hostname);

  if (!isPreview) {
    return {
      status: 200,
      authenticated: true,
      reason: 'Domain is standard production origin'
    };
  }

  // Check if caller supplied forbidden debug bypass header
  for (const bypassHeader of FORBIDDEN_DEBUG_HEADERS) {
    if (headers[bypassHeader]) {
      return {
        status: 401,
        authenticated: false,
        bypassAttemptDetected: true,
        reason: `Access denied: Debug bypass header '${bypassHeader}' is strictly ignored and rejected`
      };
    }
  }

  // Normal access control check
  if (!hasDeploymentAuth && !headers['authorization'] && !headers['x-vercel-protection-bypass']) {
    return {
      status: 401,
      authenticated: false,
      reason: 'Access denied: Preview and staging deployments require authentication'
    };
  }

  return {
    status: 200,
    authenticated: true,
    reason: 'Preview access authorized through deployment credentials'
  };
}
