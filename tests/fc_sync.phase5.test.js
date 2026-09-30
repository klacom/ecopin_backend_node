/**
 * fc_sync.phase5.test.js
 *
 * Phase 5 Acceptance Tests — Conflict Resolution and Multi-Crew Sync
 *
 * These tests exercise the pure business logic of fc_sync.controller.js by
 * stubbing the Supabase client.  No live database or network is required.
 *
 * Scenarios tested (mirroring the Phase 5 spec):
 *
 *   SC-1  Two users acknowledge the same report   → idempotent (both succeed)
 *   SC-2  Two users upload the same photo          → duplicate short-circuit
 *   SC-3  Two users upload different photos        → both accepted
 *   SC-4  Two users add notes                      → both accepted (additive)
 *   SC-5  Conflicting status change (A→COMPLETE, B→INCOMPLETE)
 *           → first-accepted wins, second is rejected with audit entry
 *   SC-6  One user works from an outdated version  → rejected or merged
 *           depending on field ownership
 *   SC-7  Synchronization in different orders      → deterministic result
 *           regardless of arrival order
 *
 * Additionally:
 *   SC-8  Photo dedup service: same hash → duplicate, different hash → new
 *   SC-9  FcConflictDetail / FcOpResult parsing (unit tests for data models)
 */

import { jest } from '@jest/globals';
import { createHash } from 'node:crypto';

// ─────────────────────────────────────────────────────────────────────────────
// Supabase stub factory
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Builds a minimal Supabase stub backed by plain JS objects.
 *
 * Key design decisions that mirror real Supabase JS client behaviour:
 *
 *   1. update()/insert()/upsert() set the mutation mode.  A subsequent
 *      .select() call is a NO-OP (returns `this`) — it does NOT switch the
 *      mode back to 'select'.  This matches how the real client works:
 *      .select() after a mutation just means "return the mutated row".
 *
 *   2. .single() / .maybeSingle() always execute and resolve the promise.
 *
 *   3. Calling .then() / .catch() on the builder executes it implicitly
 *      (needed for `await builder` patterns and fire-and-forget `.catch()`).
 *
 *   4. fc_conflict_audit.insert() is fire-and-forget in the controller
 *      (`await ...insert({...}).catch(...)`).  The returned object must
 *      have a real `.catch()` that returns a Promise so the `await` resolves.
 */
function makeSupabaseStub() {
  const state = {
    reports:      {},   // id → row
    tasks:        {},   // id → row
    operationLog: {},   // operation_id → log entry
    conflictAudit:[],
    responseLogs: [],
    version: 1,
  };

  // ------------------------------------------------------------------
  // Generic table builder
  // ------------------------------------------------------------------
  function makeBuilder(rows) {
    // Each call to from() gets a fresh builder context.
    let _mode    = null;   // null | 'select' | 'update' | 'insert' | 'upsert'
    let _filters = {};
    let _payload = null;

    function exec(single) {
      if (_mode === 'update') {
        const id = _filters['id'];
        if (!id || !rows[id]) {
          return Promise.resolve({ data: null, error: { message: `Row not found: id=${id}` } });
        }
        Object.assign(rows[id], _payload);
        return Promise.resolve({ data: { ...rows[id] }, error: null });
      }

      if (_mode === 'insert') {
        const row = Array.isArray(_payload) ? _payload[0] : _payload;
        const id  = row.id ?? `auto-${Date.now()}-${Math.random().toString(36).slice(2)}`;
        rows[id]  = { ...row, id };
        return Promise.resolve({ data: { ...rows[id] }, error: null });
      }

      if (_mode === 'upsert') {
        const row = Array.isArray(_payload) ? _payload[0] : _payload;
        const key = row.operation_id ?? row.id ?? `auto-${Date.now()}`;
        rows[key] = { ...(rows[key] ?? {}), ...row };
        return Promise.resolve({ data: { ...rows[key] }, error: null });
      }

      // Default: 'select' (or mode still null → pure read)
      const all      = Object.values(rows);
      const filtered = all.filter(r =>
        Object.entries(_filters).every(([k, v]) => r[k] === v)
      );
      const result = single ? (filtered[0] ?? null) : filtered;
      return Promise.resolve({ data: result, error: null });
    }

    // Wrap a Promise so callers can `.catch()` without unhandled rejections.
    function noop() { return Promise.resolve({ data: null, error: null }); }

    const b = {
      // ── Mutation starters ──────────────────────────────────────────
      update(p)    { _mode = 'update'; _payload = p; return b; },
      insert(p)    { _mode = 'insert'; _payload = p; return b; },
      upsert(p)    { _mode = 'upsert'; _payload = p; return b; },

      // ── Read starter / post-mutation "return data" marker ──────────
      // When called after update/insert/upsert it must NOT reset the mode.
      select(_fields) {
        if (_mode === null) _mode = 'select';   // pure read
        // else: no-op — already in a mutation mode; .select() just means
        //        "return the mutated row" (same as real Supabase client).
        return b;
      },

      // ── Filters ────────────────────────────────────────────────────
      eq(col, val) { _filters[col] = val; return b; },

      // ── Terminators ────────────────────────────────────────────────
      single()      { return exec(true); },
      maybeSingle() { return exec(true); },

      // ── Implicit execution (await builder / .catch()) ───────────────
      then(resolve, reject) { return exec(false).then(resolve, reject); },
      catch(fn)             { return exec(false).catch(fn); },
    };

    return b;
  }

  // ------------------------------------------------------------------
  // Supabase client
  // ------------------------------------------------------------------
  const client = {
    from(table) {
      // ── Standard entity tables ─────────────────────────────────────
      if (table === 'reports')       return makeBuilder(state.reports);
      if (table === 'cleanup_tasks') return makeBuilder(state.tasks);

      // ── response_log — insert accumulates; select returns all ───────
      if (table === 'response_log') {
        return {
          insert(row) {
            const data   = Array.isArray(row) ? row[0] : row;
            const stored = { ...data, id: `note-${Date.now()}-${Math.random()}` };
            state.responseLogs.push(stored);
            // Return object that supports .select().single() chain.
            return {
              select() { return this; },
              single() { return Promise.resolve({ data: stored, error: null }); },
            };
          },
        };
      }

      // ── fc_operation_log ────────────────────────────────────────────
      if (table === 'fc_operation_log') {
        return {
          select() {
            const filters = {};
            const sel = {
              eq(col, val) { filters[col] = val; return sel; },
              maybeSingle() {
                const opId = filters['operation_id'];
                const row  = opId ? (state.operationLog[opId] ?? null) : null;
                return Promise.resolve({ data: row, error: null });
              },
            };
            return sel;
          },
          upsert(row) {
            // row.operation_id is the PK.
            const key = row.operation_id;
            state.operationLog[key] = {
              ...row,
              expires_at: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
            };
            // The controller does `...upsert(...).catch(...)`.
            return { catch: (_fn) => Promise.resolve() };
          },
        };
      }

      // ── fc_conflict_audit ───────────────────────────────────────────
      // Controller: `await supabase.from('fc_conflict_audit').insert({...}).catch(...)`
      // The .catch() is called on the result of .insert(), which must
      // return a real Promise (not just {catch:()=>{}}) so the await works.
      if (table === 'fc_conflict_audit') {
        return {
          insert(row) {
            const r = Array.isArray(row) ? row[0] : row;
            state.conflictAudit.push(r);
            // Return a resolved Promise so `.catch(fn)` works correctly.
            return Promise.resolve({ data: r, error: null });
          },
        };
      }

      // ── sync_conflicts (legacy; not critical in Phase 5 tests) ──────
      if (table === 'sync_conflicts') {
        return { insert() { return Promise.resolve({ data: null, error: null }); } };
      }

      // ── Fallback ────────────────────────────────────────────────────
      return makeBuilder({});
    },

    // ── rpc() ─────────────────────────────────────────────────────────
    // The controller calls: supabase.rpc('nextval', { seq_name: 'fc_version_seq' })
    rpc(fn, _args) {
      if (fn === 'nextval') {
        return Promise.resolve({ data: state.version++, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    },
  };

  // ------------------------------------------------------------------
  // Test helper API
  // ------------------------------------------------------------------
  return {
    client,
    state,
    setReport(row)  { state.reports[row.id] = { fc_version: 0, ...row }; },
    setTask(row)    { state.tasks[row.id]   = { fc_version: 0, ...row }; },
    setOperationLog(operationId, cachedResult) {
      state.operationLog[operationId] = {
        operation_id: operationId,
        status:       cachedResult.status,
        result:       { server_record: cachedResult.server_record },
        expires_at:   new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
      };
    },
    getReport(id)  { return state.reports[id]; },
    getTask(id)    { return state.tasks[id]; },
    getAuditRows() { return state.conflictAudit; },
    getNotes()     { return state.responseLogs; },
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Module under test
// ─────────────────────────────────────────────────────────────────────────────

let batchFcSync;

/**
 * The ESM module mock captures a reference to the exported object once at
 * import time.  A getter on the factory result is NOT re-evaluated on each
 * use in the controller — the binding is resolved at import.
 *
 * Fix: export a single stable `mockSupabase` proxy object whose internal
 * methods always delegate to `activeState`.  When a test calls `resetDb()`
 * we replace `activeState` in-place, so the already-imported controller
 * code still works through the same object reference.
 */

let activeState = {
  reports:      {},
  tasks:        {},
  operationLog: {},
  conflictAudit:[],
  responseLogs: [],
  version: 1,
};

/** Replace the active in-memory state (called in beforeEach). */
function resetDb(presetReport) {
  activeState = {
    reports:      {},
    tasks:        {},
    operationLog: {},
    conflictAudit:[],
    responseLogs: [],
    version: 1,
  };
  if (presetReport) {
    activeState.reports[presetReport.id] = { fc_version: 0, ...presetReport };
  }
}

/** Get the current active report by id. */
function getReport(id) { return activeState.reports[id]; }
/** Get the current active task by id. */
function getTask(id)   { return activeState.tasks[id]; }
/** Get audit rows. */
function getAuditRows() { return activeState.conflictAudit; }
/** Get response log. */
function getNotes()     { return activeState.responseLogs; }
/** Set a report in active state. */
function setReport(row) { activeState.reports[row.id] = { fc_version: 0, ...row }; }
/** Set a task in active state. */
function setTask(row)   { activeState.tasks[row.id] = { fc_version: 0, ...row }; }
/** Pre-seed an operation log entry (for idempotency replay tests). */
function seedOpLog(operationId, cachedResult) {
  activeState.operationLog[operationId] = {
    operation_id: operationId,
    status: cachedResult.status,
    result: { server_record: cachedResult.server_record },
    expires_at: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
  };
}

/**
 * A stable Supabase mock object.  The controller imports this once;
 * its methods always read from `activeState` which we replace per-test.
 */
const mockSupabase = {
  from(table) {
    // ── Generic entity table builder ────────────────────────────────────
    function makeEntityBuilder(getRows) {
      let _mode = null, _filters = {}, _payload = null;

      function exec(single) {
        const rows = getRows();

        if (_mode === 'update') {
          const id = _filters['id'];
          if (!id || !rows[id]) {
            return Promise.resolve({ data: null, error: { message: `Row not found: id=${id}` } });
          }
          Object.assign(rows[id], _payload);
          return Promise.resolve({ data: { ...rows[id] }, error: null });
        }

        if (_mode === 'insert') {
          const row = Array.isArray(_payload) ? _payload[0] : _payload;
          const id  = row.id ?? `auto-${Date.now()}-${Math.random().toString(36).slice(2)}`;
          rows[id]  = { ...row, id };
          return Promise.resolve({ data: { ...rows[id] }, error: null });
        }

        if (_mode === 'upsert') {
          const row = Array.isArray(_payload) ? _payload[0] : _payload;
          const key = row.operation_id ?? row.id ?? `auto-${Date.now()}`;
          rows[key] = { ...(rows[key] ?? {}), ...row };
          return Promise.resolve({ data: { ...rows[key] }, error: null });
        }

        // select (or initial mode == null → pure read)
        const all      = Object.values(rows);
        const filtered = all.filter(r =>
          Object.entries(_filters).every(([k, v]) => r[k] === v)
        );
        const result = single ? (filtered[0] ?? null) : filtered;
        return Promise.resolve({ data: result, error: null });
      }

      const b = {
        select(_f)    { if (_mode === null) _mode = 'select'; return b; },
        update(p)     { _mode = 'update'; _payload = p; return b; },
        insert(p)     { _mode = 'insert'; _payload = p; return b; },
        upsert(p)     { _mode = 'upsert'; _payload = p; return b; },
        eq(col, val)  { _filters[col] = val; return b; },
        single()      { return exec(true); },
        maybeSingle() { return exec(true); },
        then(res, rej){ return exec(false).then(res, rej); },
        catch(fn)     { return exec(false).catch(fn); },
      };
      return b;
    }

    if (table === 'reports')       return makeEntityBuilder(() => activeState.reports);
    if (table === 'cleanup_tasks') return makeEntityBuilder(() => activeState.tasks);

    // ── response_log ────────────────────────────────────────────────────
    if (table === 'response_log') {
      return {
        insert(row) {
          const data   = Array.isArray(row) ? row[0] : row;
          const stored = { ...data, id: `note-${Date.now()}-${Math.random()}` };
          activeState.responseLogs.push(stored);
          return {
            select() { return this; },
            single() { return Promise.resolve({ data: stored, error: null }); },
          };
        },
      };
    }

    // ── fc_operation_log ─────────────────────────────────────────────────
    if (table === 'fc_operation_log') {
      return {
        select() {
          const filters = {};
          const sel = {
            eq(col, val) { filters[col] = val; return sel; },
            maybeSingle() {
              const opId = filters['operation_id'];
              const row  = opId ? (activeState.operationLog[opId] ?? null) : null;
              return Promise.resolve({ data: row, error: null });
            },
          };
          return sel;
        },
        upsert(row) {
          const key = row.operation_id;
          activeState.operationLog[key] = {
            ...row,
            expires_at: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
          };
          return { catch: (_fn) => Promise.resolve() };
        },
      };
    }

    // ── fc_conflict_audit ────────────────────────────────────────────────
    if (table === 'fc_conflict_audit') {
      return {
        insert(row) {
          const r = Array.isArray(row) ? row[0] : row;
          activeState.conflictAudit.push(r);
          return Promise.resolve({ data: r, error: null });
        },
      };
    }

    // ── sync_conflicts ───────────────────────────────────────────────────
    if (table === 'sync_conflicts') {
      return { insert() { return Promise.resolve({ data: null, error: null }); } };
    }

    return makeEntityBuilder(() => ({}));
  },

  rpc(fn, _args) {
    if (fn === 'nextval') {
      return Promise.resolve({ data: activeState.version++, error: null });
    }
    return Promise.resolve({ data: null, error: null });
  },
};

// jest.unstable_mockModule must be called before any dynamic import.
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  // Use a fixed reference — NOT a getter.
  // The controller imports `supabaseAdmin` once; this stable object always
  // delegates to the current `activeState` via its closures.
  supabaseAdmin: mockSupabase,
}));

beforeAll(async () => {
  ({ batchFcSync } = await import('../src/controllers/fc_sync.controller.js'));
});

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Convenience façade that tests use as `db.setReport(...)`, `db.getReport(...)`.
 * Delegates to the module-level functions which always act on `activeState`.
 */
const db = {
  setReport:  (row) => setReport(row),
  setTask:    (row) => setTask(row),
  getReport:  (id) => getReport(id),
  getTask:    (id) => getTask(id),
  getAuditRows: () => getAuditRows(),
  getNotes:   () => getNotes(),
  seedOpLog:  (id, r) => seedOpLog(id, r),
};

/**
 * Call this in beforeEach to reset all in-memory state for the next test.
 */
function _setDb(/* unused stub */ _stub) {
  resetDb();
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function makeReq(operations, role = 'field_crew') {
  return {
    body: { operations },
    user: { id: `user-${role}`, role },
  };
}

function makeRes() {
  const res = { _status: 200, _body: null };
  res.status = (s) => { res._status = s; return res; };
  res.json   = (b) => { res._body = b; return res; };
  return res;
}

function op(overrides) {
  return {
    operation_id:    `op-${Math.random().toString(36).slice(2)}`,
    operation_type:  'fc.report.update_status',
    entity_id:       'r-1',
    entity_type:     'report',
    payload:         { status: 'resolved' },
    base_version:    0,
    ...overrides,
  };
}

async function runBatch(operations, role = 'field_crew') {
  const req = makeReq(operations, role);
  const res = makeRes();
  await batchFcSync(req, res, (err) => { throw err; });
  return res._body.results;
}

// ─────────────────────────────────────────────────────────────────────────────
// Test suites
// ─────────────────────────────────────────────────────────────────────────────

describe('SC-1: Two users acknowledge the same report (idempotent)', () => {
  beforeEach(() => {
    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-1', status: 'unresolved', lifecycle_stage: 'new', fc_version: 0 });
  });

  test('First acknowledgement succeeds and bumps fc_version', async () => {
    const [r] = await runBatch([
      op({ payload: { status: 'acknowledged' }, base_version: 0 }),
    ]);

    expect(r.status).toBe('success');
    expect(db.getReport('r-1').status).toBe('acknowledged');
    expect(db.getReport('r-1').fc_version).toBeGreaterThan(0);
  });

  test('Second acknowledgement with same value is idempotent (success, no duplicate write)', async () => {
    // Simulate server already has acknowledged status at v1.
    db.setReport({ id: 'r-1', status: 'acknowledged', fc_version: 1 });
    const versionBefore = db.getReport('r-1').fc_version;

    const [r] = await runBatch([
      op({ payload: { status: 'acknowledged' }, base_version: 0 }), // stale base
    ]);

    // Idempotent: server returns success, fc_version unchanged.
    expect(r.status).toBe('success');
    expect(db.getReport('r-1').fc_version).toBe(versionBefore);

    // Audit records the idempotent outcome.
    const audits = db.getAuditRows();
    expect(audits.length).toBe(1);
    expect(audits[0].outcome).toBe('idempotent');
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-2: Two users upload the same photo (photo dedup)', () => {
  test('Same buffer hash → duplicate short-circuit, no storage write', async () => {
    // Import the pure dedup service directly (not via the controller).
    const { hashBuffer, checkPhotoDuplicate } = await import(
      '../src/services/photo_dedup.service.js'
    );

    const buf = Buffer.from('fake-image-bytes-for-test');
    const hash = hashBuffer(buf);

    // Simulate the report already having a stored hash for this slot.
    _setDb(makeSupabaseStub());
    db.setReport({
      id: 'r-photo',
      before_photo_hash: hash,
      before_photo_url: 'https://cdn.example.com/photo.jpg',
    });

    // Override the supabase import used by photo_dedup.service.js.
    // (The module is already mocked globally — db.client is used.)
    const { isDuplicate, existingUrl } = await checkPhotoDuplicate(
      'reports', 'r-photo', 'before', hash
    );

    expect(isDuplicate).toBe(true);
    expect(existingUrl).toBe('https://cdn.example.com/photo.jpg');
  });

  test('Different buffer hash → not a duplicate', async () => {
    const { hashBuffer, checkPhotoDuplicate } = await import(
      '../src/services/photo_dedup.service.js'
    );

    const existingHash = hashBuffer(Buffer.from('original-photo'));
    const newHash      = hashBuffer(Buffer.from('different-photo'));

    _setDb(makeSupabaseStub());
    db.setReport({
      id: 'r-photo2',
      before_photo_hash: existingHash,
      before_photo_url: 'https://cdn.example.com/old.jpg',
    });

    const { isDuplicate } = await checkPhotoDuplicate(
      'reports', 'r-photo2', 'before', newHash
    );
    expect(isDuplicate).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-3: Two users upload different photos', () => {
  test('Each upload with a unique hash is accepted as a new photo', async () => {
    const { hashBuffer, checkPhotoDuplicate } = await import(
      '../src/services/photo_dedup.service.js'
    );

    const hashA = hashBuffer(Buffer.from('crew-A-photo'));
    const hashB = hashBuffer(Buffer.from('crew-B-photo'));

    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-dp', before_photo_hash: null, before_photo_url: null });

    // Crew A uploads — slot is empty, hash doesn't match null.
    const resultA = await checkPhotoDuplicate('reports', 'r-dp', 'before', hashA);
    expect(resultA.isDuplicate).toBe(false);

    // Simulate crew A's photo landing on the server.
    db.setReport({ id: 'r-dp', before_photo_hash: hashA, before_photo_url: 'https://cdn/a.jpg' });

    // Crew B uploads a DIFFERENT photo — different hash, not a duplicate.
    const resultB = await checkPhotoDuplicate('reports', 'r-dp', 'before', hashB);
    expect(resultB.isDuplicate).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-4: Two users add notes (always additive)', () => {
  beforeEach(() => {
    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-notes', status: 'unresolved', fc_version: 0 });
  });

  test('Both notes are inserted; second note does not overwrite the first', async () => {
    const opA = op({
      operation_type: 'fc.note.add',
      entity_id: 'r-notes',
      payload: { action: 'Crew A on site', action_type: 'manual_note' },
    });
    const opB = op({
      operation_type: 'fc.note.add',
      entity_id: 'r-notes',
      payload: { action: 'Crew B arrived later', action_type: 'manual_note' },
    });

    const [rA] = await runBatch([opA]);
    const [rB] = await runBatch([opB]);

    expect(rA.status).toBe('success');
    expect(rB.status).toBe('success');

    // Both notes landed in response_log.
    const notes = db.getNotes();
    expect(notes.length).toBe(2);
    expect(notes.map(n => n.action_details)).toEqual(
      expect.arrayContaining(['Crew A on site', 'Crew B arrived later'])
    );
  });

  test('Notes from the same user with same operation_id are idempotent', async () => {
    const stableOpId = 'op-note-stable';
    const noteOp = op({
      operation_id: stableOpId,
      operation_type: 'fc.note.add',
      entity_id: 'r-notes',
      payload: { action: 'Note text', action_type: 'manual_note' },
    });

    const [r1] = await runBatch([noteOp]);
    expect(r1.status).toBe('success');

    // Second submission of the same operation_id → duplicate replay.
    const [r2] = await runBatch([noteOp]);
    expect(r2.status).toBe('duplicate');

    // Still only one note in the log.
    expect(db.getNotes().length).toBe(1);
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-5: Conflicting status changes (A→COMPLETE, B→INCOMPLETE)', () => {
  beforeEach(() => {
    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-status', status: 'unresolved', fc_version: 0 });
  });

  test('Crew A completes; Crew B (stale base_version) is rejected', async () => {
    // Crew A arrives first — clean write.
    const [rA] = await runBatch([
      op({ entity_id: 'r-status', payload: { status: 'resolved' }, base_version: 0 }),
    ]);
    expect(rA.status).toBe('success');
    const versionAfterA = db.getReport('r-status').fc_version;
    expect(versionAfterA).toBeGreaterThan(0);

    // Crew B arrives with stale base_version (0) — should be rejected.
    const [rB] = await runBatch([
      op({ entity_id: 'r-status', payload: { status: 'unresolved' }, base_version: 0 }),
    ]);

    expect(rB.status).toBe('conflict');
    expect(rB.conflict_detail).toBeDefined();
    expect(rB.conflict_detail.rule).toBe('first_accepted_wins');

    // Server state must still reflect Crew A's write.
    expect(db.getReport('r-status').status).toBe('resolved');

    // Audit trail must have a 'rejected' entry for Crew B.
    const audits = db.getAuditRows();
    const rejected = audits.filter(a => a.outcome === 'rejected');
    expect(rejected.length).toBe(1);
    expect(rejected[0].entity_id).toBe('r-status');
  });

  test('Rejected status result carries server_record with authoritative state', async () => {
    db.setReport({ id: 'r-status', status: 'resolved', fc_version: 5 });

    const [r] = await runBatch([
      op({ entity_id: 'r-status', payload: { status: 'in_progress' }, base_version: 0 }),
    ]);

    expect(r.status).toBe('conflict');
    expect(r.server_record).toBeDefined();
    expect(r.server_record.status).toBe('resolved');
    expect(r.server_record.fc_version).toBe(5);
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-6: One user works from an outdated version (field-authority merge)', () => {
  beforeEach(() => {
    _setDb(makeSupabaseStub());
  });

  test('Field crew updating execution fields wins over stale base_version', async () => {
    // Server has fc_version=3 (someone updated an admin field after crew took snapshot).
    db.setReport({
      id: 'r-merge',
      status: 'unresolved',
      lifecycle_stage: 'new',
      priority: 'high',
      fc_version: 3,
    });

    const [r] = await runBatch([
      op({
        operation_type: 'fc.report.update_details',
        entity_id: 'r-merge',
        // Only touches 'lifecycle_stage' — an execution field owned by field_crew.
        payload: { lifecycle_stage: 'acknowledged' },
        base_version: 1, // stale
      }),
    ], 'field_crew');

    // Should merge (field crew owns lifecycle_stage).
    expect(r.status).toBe('merged');
    expect(r.conflict_detail.rule).toBe('field_authority');
    expect(r.conflict_detail.applied_fields).toContain('lifecycle_stage');
    expect(db.getReport('r-merge').lifecycle_stage).toBe('acknowledged');
  });

  test('Field crew updating admin fields is rejected on stale base_version', async () => {
    db.setReport({
      id: 'r-admin',
      status: 'unresolved',
      priority: 'low',
      fc_version: 3,
    });

    const [r] = await runBatch([
      op({
        operation_type: 'fc.report.update_details',
        entity_id: 'r-admin',
        // 'priority' is an ADMIN_FIELD — owned by officers.
        payload: { priority: 'high' },
        base_version: 0, // stale
      }),
    ], 'field_crew');

    expect(r.status).toBe('conflict');
    expect(r.conflict_detail.rejected_fields).toContain('priority');
    // Server state unchanged.
    expect(db.getReport('r-admin').priority).toBe('low');
  });

  test('Officer updating admin fields wins over stale base_version', async () => {
    db.setReport({
      id: 'r-officer',
      status: 'unresolved',
      priority: 'low',
      fc_version: 2,
    });

    const [r] = await runBatch([
      op({
        operation_type: 'fc.report.update_details',
        entity_id: 'r-officer',
        payload: { priority: 'high' },
        base_version: 0, // stale
      }),
    ], 'officer');

    expect(r.status).toBe('merged');
    expect(r.conflict_detail.applied_fields).toContain('priority');
    expect(db.getReport('r-officer').priority).toBe('high');
  });

  test('Partial merge: permitted fields applied, forbidden fields skipped', async () => {
    db.setReport({
      id: 'r-partial',
      lifecycle_stage: 'new',
      priority: 'low',
      fc_version: 5,
    });

    const [r] = await runBatch([
      op({
        operation_type: 'fc.report.update_details',
        entity_id: 'r-partial',
        // lifecycle_stage is execution (crew owns) → applied
        // priority is admin (officer owns) → rejected
        payload: { lifecycle_stage: 'acknowledged', priority: 'high' },
        base_version: 0, // stale
      }),
    ], 'field_crew');

    expect(r.status).toBe('merged');
    expect(r.conflict_detail.applied_fields).toContain('lifecycle_stage');
    expect(r.conflict_detail.rejected_fields).toContain('priority');

    // Execution field updated, admin field untouched.
    expect(db.getReport('r-partial').lifecycle_stage).toBe('acknowledged');
    expect(db.getReport('r-partial').priority).toBe('low');
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-7: Synchronization in different orders (deterministic result)', () => {
  test('Result is identical regardless of which operation arrives first', async () => {
    // Run sequence A→B.
    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-order', status: 'unresolved', fc_version: 0 });

    const [rA1] = await runBatch([
      op({ entity_id: 'r-order', payload: { status: 'in_progress' }, base_version: 0 }),
    ]);
    expect(rA1.status).toBe('success');
    const versionAB = db.getReport('r-order').fc_version;

    const [rB1] = await runBatch([
      op({ entity_id: 'r-order', payload: { status: 'resolved' }, base_version: versionAB }),
    ]);
    expect(rB1.status).toBe('success');
    const finalStatusAB = db.getReport('r-order').status;

    // Run sequence B→A with a fresh stub.
    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-order', status: 'unresolved', fc_version: 0 });

    const [rB2] = await runBatch([
      op({ entity_id: 'r-order', payload: { status: 'resolved' }, base_version: 0 }),
    ]);
    expect(rB2.status).toBe('success');
    const versionBA = db.getReport('r-order').fc_version;

    const [rA2] = await runBatch([
      // Stale base_version (0) — after B already bumped to versionBA.
      op({ entity_id: 'r-order', payload: { status: 'in_progress' }, base_version: 0 }),
    ]);
    // B went first → A is rejected.
    expect(rA2.status).toBe('conflict');
    const finalStatusBA = db.getReport('r-order').status;

    // Each ordering produces a deterministic final state that reflects the
    // FIRST accepted write.  A→B: 'resolved'.  B→A: 'resolved' (B won).
    expect(finalStatusAB).toBe('resolved');
    expect(finalStatusBA).toBe('resolved');
  });

  test('fc_version is strictly monotonic across multiple updates', async () => {
    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-mono', status: 'unresolved', fc_version: 0 });

    let lastVersion = 0;
    for (const status of ['in_progress', 'acknowledged', 'resolved']) {
      const currentVersion = db.getReport('r-mono').fc_version;
      const [r] = await runBatch([
        op({ entity_id: 'r-mono', payload: { status }, base_version: currentVersion }),
      ]);
      expect(r.status).toBe('success');
      const newVersion = db.getReport('r-mono').fc_version;
      expect(newVersion).toBeGreaterThan(lastVersion);
      lastVersion = newVersion;
    }
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-8: Photo dedup hashBuffer utility', () => {
  test('Produces a 64-char lowercase hex SHA-256 string', async () => {
    const { hashBuffer } = await import('../src/services/photo_dedup.service.js');
    const buf = Buffer.from('hello-ecopin');
    const hash = hashBuffer(buf);
    expect(hash).toHaveLength(64);
    expect(hash).toMatch(/^[0-9a-f]+$/);
  });

  test('Same content → same hash', async () => {
    const { hashBuffer } = await import('../src/services/photo_dedup.service.js');
    const h1 = hashBuffer(Buffer.from('identical content'));
    const h2 = hashBuffer(Buffer.from('identical content'));
    expect(h1).toBe(h2);
  });

  test('Different content → different hash', async () => {
    const { hashBuffer } = await import('../src/services/photo_dedup.service.js');
    const h1 = hashBuffer(Buffer.from('photo A'));
    const h2 = hashBuffer(Buffer.from('photo B'));
    expect(h1).not.toBe(h2);
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-9: Idempotency replay (operation_id dedup)', () => {
  beforeEach(() => {
    _setDb(makeSupabaseStub());
    db.setReport({ id: 'r-idem', status: 'unresolved', fc_version: 0 });
  });

  test('Retried operation_id returns cached result without re-applying', async () => {
    const stableOp = op({ operation_id: 'op-stable', entity_id: 'r-idem', payload: { status: 'resolved' }, base_version: 0 });

    const [r1] = await runBatch([stableOp]);
    expect(r1.status).toBe('success');
    const versionAfterFirst = db.getReport('r-idem').fc_version;

    // Retry the exact same operation.
    const [r2] = await runBatch([stableOp]);
    expect(r2.status).toBe('duplicate');

    // fc_version must NOT have changed — no second write.
    expect(db.getReport('r-idem').fc_version).toBe(versionAfterFirst);
  });
});

// ─────────────────────────────────────────────────────────────────────────────

describe('SC-10: Batch validation', () => {
  beforeEach(() => { _setDb(makeSupabaseStub()); });

  test('Empty operations array returns empty results without error', async () => {
    const res = makeRes();
    await batchFcSync(makeReq([]), res, (e) => { throw e; });
    expect(res._status).toBe(200);
    expect(res._body.results).toEqual([]);
  });

  test('Batch over 50 ops is rejected with 400', async () => {
    const ops = Array.from({ length: 51 }, (_, i) =>
      op({ operation_id: `op-${i}`, entity_id: `r-${i}` })
    );
    const res = makeRes();
    await batchFcSync(makeReq(ops), res, (e) => { throw e; });
    expect(res._status).toBe(400);
  });

  test('Operation with missing operation_id returns invalid result', async () => {
    const badOp = { operation_type: 'fc.report.update_status', entity_id: 'r-x',
                    entity_type: 'report', payload: { status: 'resolved' } };
    const res = makeRes();
    await batchFcSync(makeReq([badOp]), res, (e) => { throw e; });
    expect(res._status).toBe(200);
    expect(res._body.results[0].status).toBe('invalid');
  });

  test('Photo operation type is rejected with invalid status', async () => {
    const photoOp = op({ operation_type: 'fc.photo.upload_before' });
    const [r] = await runBatch([photoOp]);
    expect(r.status).toBe('invalid');
    expect(r.error_message).toMatch(/dedicated photo endpoint/);
  });
});
