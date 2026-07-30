/**
 * Centralized role definitions for EcoPin RBAC.
 *
 * WHY: Every route file and controller previously hardcoded role arrays
 * like ['lgu', 'admin']. By centralizing them here we get:
 *   1. A single source of truth — add a role once, not in 12 files.
 *   2. Safer refactors — rename a role and the linter catches every import.
 *   3. Readable route files — `authorize(ROLES.DESK_OPS)` is self-documenting.
 */

// ── Individual role identifiers ───────────────────────────────────────
export const ROLE = Object.freeze({
  ADMIN: 'admin',
  OFFICER: 'officer',       // Desk officer (was 'lgu')
  FIELD_CREW: 'field_crew', // On-site field operations
  CITIZEN: 'citizen',       // Public residents
});

// ── All valid roles (used for input validation) ───────────────────────
export const ALL_ROLES = Object.freeze(
  Object.values(ROLE)
);

// ── Permission groups (used in authorize() middleware) ─────────────────
// Each group answers: "Which roles can access this category of routes?"
export const ROLE_GROUPS = Object.freeze({
  /** Full system administration — settings, user mgmt, audit logs */
  ADMIN_ONLY: [ROLE.ADMIN],

  /** Desktop dashboard operations — clusters, reports mgmt, manual review, strikes */
  DESK_OPS: [ROLE.ADMIN, ROLE.OFFICER],

  /** Field operations — cleanup task execution, photo uploads, response logging */
  FIELD_OPS: [ROLE.ADMIN, ROLE.OFFICER, ROLE.FIELD_CREW],

  /** System statistics — viewable by admin and officer */
  STATS_VIEWERS: [ROLE.ADMIN, ROLE.OFFICER],

  /** Report management — status updates, validation, lifecycle changes */
  REPORT_MGMT: [ROLE.ADMIN, ROLE.OFFICER],
});
