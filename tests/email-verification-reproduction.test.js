import { jest } from '@jest/globals';

// This staged file is intended to be copied to backend/tests before running.
// Every external boundary is replaced; no Supabase client or SMTP connection loads.
const updateUserById = jest.fn();
const admin = { from: jest.fn(), rpc: jest.fn(), auth: { admin: { updateUserById } } };
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabase: {}, supabaseAdmin: admin }));
jest.unstable_mockModule('../src/config/index.js', () => ({ MOBILE_REDIRECT_URL: 'ecopin://auth' }));
jest.unstable_mockModule('../src/services/email.service.js', () => ({
  generateVerificationToken: jest.fn(() => { throw new Error('Email generation must not run in redemption tests'); }),
  sendVerificationEmail: jest.fn(() => { throw new Error('Email sending must not run in redemption tests'); }),
}));
const { verifyEmail } = await import('../src/controllers/auth.controller.js');

const TOKEN = '11111111-1111-4111-8111-111111111111';
let state, fault, readGate, readsWaiting, releaseReads, consoleError, fetchGuard;

function response() {
  return {
    statusCode: null, body: null, headers: {},
    set(name, value) { this.headers[name] = value; return this; },
    status(code) { this.statusCode = code; return this; },
    send(body) { this.body = body; return this; },
    json(body) { this.body = body; return this; },
  };
}

// A stateful PostgREST boundary fake: reads observe their own snapshots, writes
// mutate shared state, and SDK-style failures resolve {error} rather than throw.
function query(table) {
  let operation = 'select', payload, filters = [];
  const builder = {
    select() { return builder; },
    update(value) { operation = 'update'; payload = value; return builder; },
    eq(column, value) { filters.push(row => row[column] === value); return builder; },
    is(column, value) { filters.push(row => row[column] === value); return builder; },
    single() { return execute(true); },
    maybeSingle() { return execute(true); },
    then(resolve, reject) { return execute(false).then(resolve, reject); },
  };
  async function execute(single) {
    const row = table === 'email_verifications' ? state.verification : state.profile;
    if (operation === 'select') {
      const snapshot = row && filters.every(matches => matches(row)) ? { ...row } : null;
      if (table === 'email_verifications' && readGate) {
        readsWaiting += 1;
        if (readsWaiting === 2) releaseReads();
        await readGate;
      }
      return { data: single ? snapshot : (snapshot ? [snapshot] : []), error: null };
    }
    if (table === 'profiles' && fault === 'profile_error') {
      return { data: null, error: { code: '42501', message: 'Synthetic profile write denied' }, count: null };
    }
    if (table === 'profiles' && fault === 'profile_missing') {
      return { data: single ? null : [], error: null, count: 0 };
    }
    const matches = row && filters.every(matchesRow => matchesRow(row));
    if (matches) Object.assign(row, payload);
    return { data: single ? (matches ? { ...row } : null) : (matches ? [{ ...row }] : []), error: null, count: matches ? 1 : 0 };
  }
  return builder;
}

beforeEach(() => {
  state = {
    verification: { id: 'synthetic-verification', user_id: 'synthetic-citizen', token: TOKEN, used_at: null, expires_at: '2099-01-01T00:00:00.000Z' },
    profile: { id: 'synthetic-citizen', is_email_verified: false },
  };
  fault = null; readGate = null; readsWaiting = 0; releaseReads = null;
  admin.from.mockReset();
  admin.from.mockImplementation(table => {
    if (!['email_verifications', 'profiles'].includes(table)) throw new Error(`Unexpected database table: ${table}`);
    return query(table);
  });
  updateUserById.mockReset();
  updateUserById.mockResolvedValue({ data: { user: { id: 'synthetic-citizen' } }, error: null });
  admin.rpc.mockReset();
  admin.rpc.mockImplementation(async (name, args) => {
    if (name !== 'complete_email_verification') throw new Error('Unexpected RPC');
    const row = state.verification;
    if (fault === 'profile_error') return {data:null,error:{code:'42501'}};
    if (!row || row.id !== args.p_verification_id || row.user_id !== args.p_user_id
        || row.used_at || Date.parse(row.expires_at) <= Date.now() || !state.profile) {
      return {data:false,error:null};
    }
    state.profile.is_email_verified = true;
    row.used_at = new Date().toISOString();
    return {data:true,error:null};
  });
  consoleError = jest.spyOn(console, 'error').mockImplementation(() => {});
  fetchGuard = jest.spyOn(globalThis, 'fetch').mockImplementation(() => { throw new Error('Network forbidden in isolated verification reproduction'); });
});

afterEach(() => { consoleError.mockRestore(); fetchGuard.mockRestore(); });

async function redeem() {
  const res = response();
  await verifyEmail({ query: { token: TOKEN } }, res, error => { throw error; });
  return res;
}

test('valid redemption reports success and verifies the existing profile', async () => {
  const res = await redeem();
  expect(res.statusCode).toBe(200);
  expect(res.headers['Cache-Control']).toBe('no-store');
  expect(res.body).toContain('Email verified successfully!');
  expect(state.profile.is_email_verified).toBe(true);
  expect(state.verification.used_at).toBeTruthy();
});

test('a rejected profile update cannot produce verification success', async () => {
  fault = 'profile_error';
  const res = await redeem();
  expect(state.profile.is_email_verified).toBe(false);
  expect(res.statusCode).not.toBe(200);
  expect(res.body).not.toContain('Email verified successfully!');
  expect(state.verification.used_at).toBeNull();
});

test('a profile update matching zero rows cannot produce verification success', async () => {
  fault = 'profile_missing';
  state.profile = null;
  const res = await redeem();
  expect(res.statusCode).not.toBe(200);
  expect(res.body).not.toContain('Email verified successfully!');
  expect(state.verification.used_at).toBeNull();
});

test('a resolved Supabase Auth admin error cannot produce verification success', async () => {
  updateUserById.mockResolvedValue({ data: { user: null }, error: { status: 503, message: 'Synthetic Auth service unavailable' } });
  const res = await redeem();
  expect(res.statusCode).not.toBe(200);
  expect(res.body).not.toContain('Email verified successfully!');
  expect(state.verification.used_at).toBeNull();
  expect(state.profile.is_email_verified).toBe(false);
});

test.each([undefined, '', ['not-a-token'], {}, 'bad-token'])('malformed token %p fails before any privileged operation', async token => {
  const res = response();
  await verifyEmail({query:{token}}, res);
  expect(res.statusCode).toBe(400);
  expect(admin.from).not.toHaveBeenCalled();
  expect(updateUserById).not.toHaveBeenCalled();
  expect(admin.rpc).not.toHaveBeenCalled();
});

test('expired token fails without confirming Auth or consuming the token', async () => {
  state.verification.expires_at = '2000-01-01T00:00:00Z';
  const res = await redeem();
  expect(res.statusCode).toBe(400);
  expect(updateUserById).not.toHaveBeenCalled();
  expect(state.verification.used_at).toBeNull();
});

test('a mismatched Auth response cannot verify the profile', async () => {
  updateUserById.mockResolvedValue({data:{user:{id:'another-user'}},error:null});
  const res = await redeem();
  expect(res.statusCode).toBe(503);
  expect(state.profile.is_email_verified).toBe(false);
  expect(state.verification.used_at).toBeNull();
});

test('a thrown dependency error cannot put token details in logs', async () => {
  updateUserById.mockRejectedValue(new Error('Secret token=' + TOKEN));
  const res = await redeem();
  expect(res.statusCode).toBe(500);
  expect(JSON.stringify(consoleError.mock.calls)).not.toContain(TOKEN);
  expect(state.profile.is_email_verified).toBe(false);
});

test('two overlapping redemptions of one unused token have exactly one success', async () => {
  // Both reads take an unused-token snapshot before either write proceeds.
  // This explicit barrier reproduces the race without timers or scheduler luck.
  readGate = new Promise(resolve => { releaseReads = resolve; });
  const responses = await Promise.all([redeem(), redeem()]);
  expect(readsWaiting).toBe(2);
  expect(responses.filter(res => res.statusCode === 200)).toHaveLength(1);
  expect(responses.filter(res => res.body.includes('Email verified successfully!'))).toHaveLength(1);
});
