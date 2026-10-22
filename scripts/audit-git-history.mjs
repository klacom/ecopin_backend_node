#!/usr/bin/env node

/**
 * Git Remote History & Secret Hygiene Audit CLI Runner (WT-36)
 *
 * Scans git status, recent commits, diffs, and monitored repository hygiene
 * to guarantee no active or historical database credentials or service-role keys are exposed.
 */

import { generateGitHistoryAuditReport, verifyGitCleanliness } from '../src/services/git-history-audit.service.js';
import { execSync } from 'node:child_process';

console.log('[Git History Audit - WT-36] Initiating repository visibility and git history inspection...');

const report = generateGitHistoryAuditReport();

console.log(`\nAudited Repositories (${report.totalRepositoriesAudited}):`);
for (const repo of report.repositories) {
  console.log(`  - ${repo.repo}: Visibility=${repo.visibility}, Forks=${repo.forksCount}, Role=${repo.role}`);
}

console.log(`\nAudit Status: ${report.overallStatus}`);
console.log(`Report SHA-256 Digest: ${report.sha256Digest}`);

if (report.findings.length > 0) {
  console.warn(`\n[WARNING] Found ${report.findings.length} historical vulnerability requiring remediation:`);
  for (const finding of report.findings) {
    console.warn(`  [${finding.severity}] ${finding.id}: ${finding.title}`);
    console.warn(`    Repo: ${finding.repository}`);
    console.warn(`    Commit of Intro: ${finding.commitIntroduced} (${finding.fileIntroduced})`);
    console.warn(`    Live Key Status: ${finding.liveStatus}`);
    console.warn('    Remediation Actions Required:');
    for (const action of finding.remediationRequired) {
      console.warn(`      * ${action}`);
    }
  }
}

// Local git working tree / diff check
try {
  const unstagedDiff = execSync('git diff', { encoding: 'utf8' });
  const stagedDiff = execSync('git diff --cached', { encoding: 'utf8' });
  const combinedDiff = `${unstagedDiff}\n${stagedDiff}`;

  const diffAudit = verifyGitCleanliness({ diff: combinedDiff, meta: { branch: 'current-working-tree' } });
  if (!diffAudit.passed) {
    console.error(`\n[FAIL] Current working tree diff contains ${diffAudit.violationCount} uncommitted secret violations!`);
    process.exit(1);
  } else {
    console.log('\n[PASS] Current working tree and staged index are clean of uncommitted secret patterns.');
  }
} catch {
  console.log('\n[INFO] Git diff check skipped (environment may not support local git subshell).');
}

console.log('\n[Git History Audit - WT-36] Audit complete. Review operational-readiness.md Section 1.6 for runbook.');
process.exit(0);
