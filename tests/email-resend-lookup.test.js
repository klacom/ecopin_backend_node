import { jest } from '@jest/globals';

// Copy into backend/tests to use its ESM package and Jest configuration.
// Every external boundary is mocked; no SDK, Auth client, or SMTP transport loads.
const rpc = jest.fn(), listUsers = jest.fn(), from = jest.fn();
const generateVerificationToken = jest.fn(), sendVerificationEmail = jest.fn();
const supabaseAdmin = { rpc, from, auth: { admin: { listUsers } } };
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin, supabase: {} }));
jest.unstable_mockModule('../src/config/index.js', () => ({ MOBILE_REDIRECT_URL: 'ecopin://auth' }));
jest.unstable_mockModule('../src/services/email.service.js', () => ({ generateVerificationToken, sendVerificationEmail }));
const { resendVerification } = await import('../src/controllers/auth.controller.js');

const TARGET_ID = '22222222-2222-4222-8222-222222222222';
const TARGET_EMAIL = 'later-citizen@example.invalid';
const GENERIC_MESSAGE = 'If an account exists, a verification email has been sent.';
const SECRET = 'synthetic-private-lookup-error';
let consoleError, consoleLog, fetchGuard, profile;

function response() {
  return {
    code: null, body: null,
    status(code) { this.code = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

beforeEach(() => {
  profile = { is_email_verified: false };
  rpc.mockReset(); rpc.mockResolvedValue({ data: TARGET_ID, error: null });
  listUsers.mockReset();
  // Auth's first page contains another account; the requested account exists
  // beyond that page and is represented by the exact lookup RPC result.
  listUsers.mockResolvedValue({ data: { users: [{ id: 'first-page-citizen', email: 'first-page@example.invalid' }] }, error: null });
  from.mockReset();
  from.mockImplementation(table => {
    if (table !== 'profiles') throw new Error('Unexpected database table');
    return { select: () => ({ eq: () => ({ single: async () => ({ data: profile, error: null }) }) }) };
  });
  generateVerificationToken.mockReset(); generateVerificationToken.mockResolvedValue('synthetic-delivered-token');
  sendVerificationEmail.mockReset(); sendVerificationEmail.mockResolvedValue(undefined);
  consoleError = jest.spyOn(console, 'error').mockImplementation(() => {});
  consoleLog = jest.spyOn(console, 'log').mockImplementation(() => {});
  fetchGuard = jest.spyOn(globalThis, 'fetch').mockImplementation(() => { throw new Error('Network forbidden in resend lookup tests'); });
});

afterEach(() => { consoleError.mockRestore(); consoleLog.mockRestore(); fetchGuard.mockRestore(); });

async function resend(email = TARGET_EMAIL) {
  const res = response(), next = jest.fn();
  await resendVerification({ body: { email } }, res, next);
  expect(next).not.toHaveBeenCalled();
  expect(res.code).toBe(200);
  expect(res.body).toEqual({ message: GENERIC_MESSAGE });
  return res;
}

test('an unverified account beyond the first Auth page receives its verification email', async () => {
  await resend();
  expect(generateVerificationToken).toHaveBeenCalledWith(TARGET_ID);
  expect(sendVerificationEmail).toHaveBeenCalledWith(TARGET_EMAIL, 'synthetic-delivered-token');
});

test('resend uses an exact privileged lookup without listing all Auth users', async () => {
  await resend();
  expect(rpc).toHaveBeenCalledWith('find_email_verification_user', { p_email: TARGET_EMAIL });
  expect(listUsers).not.toHaveBeenCalled();
});

test('uppercase and surrounding whitespace normalize before lookup and delivery', async () => {
  await resend('  LATER-CITIZEN@EXAMPLE.INVALID  ');
  expect(rpc).toHaveBeenCalledWith('find_email_verification_user', { p_email: TARGET_EMAIL });
  expect(sendVerificationEmail).toHaveBeenCalledWith(TARGET_EMAIL, 'synthetic-delivered-token');
});

test.each(['missing', 'verified', 'null'])('%s lookup outcome returns the generic response without generating or sending a token', async scenario => {
  // The lookup contract returns NULL for both missing and already verified users.
  // A missing response payload is likewise not an eligible recipient.
  rpc.mockResolvedValue({ data: scenario === 'missing' ? undefined : null, error: null });
  if (scenario === 'verified') profile = { is_email_verified: true };
  await resend();
  expect(rpc).toHaveBeenCalledWith('find_email_verification_user', { p_email: TARGET_EMAIL });
  expect(generateVerificationToken).not.toHaveBeenCalled();
  expect(sendVerificationEmail).not.toHaveBeenCalled();
});

test('distributed issuance deferral sends no null-token email', async () => {
  generateVerificationToken.mockResolvedValue(null);
  await resend();
  expect(generateVerificationToken).toHaveBeenCalledWith(TARGET_ID);
  expect(sendVerificationEmail).not.toHaveBeenCalled();
});

test.each(['resolved', 'thrown'])('%s lookup failure returns the generic response and exposes no private error detail', async scenario => {
  const error = new Error(SECRET);
  if (scenario === 'resolved') rpc.mockResolvedValue({ data: null, error: { code: '42501', message: SECRET, details: SECRET } });
  else rpc.mockRejectedValue(error);
  const res = await resend();
  expect(rpc).toHaveBeenCalledWith('find_email_verification_user', { p_email: TARGET_EMAIL });
  expect(generateVerificationToken).not.toHaveBeenCalled();
  expect(sendVerificationEmail).not.toHaveBeenCalled();
  expect(JSON.stringify([res.body, ...consoleError.mock.calls, ...consoleLog.mock.calls])).not.toContain(SECRET);
});

test.each([{}, [], 123, 'a@', 'a@b@c', 'a@example.invalid\nBcc: other@example.invalid', 'a'.repeat(255)+'@example.invalid'])('invalid email input is rejected before lookup: %j', async email => {
  const res=response();
  await resendVerification({body:{email}},res,jest.fn());
  expect(res.code).toBe(400);
  expect(rpc).not.toHaveBeenCalled();
  expect(listUsers).not.toHaveBeenCalled();
  expect(sendVerificationEmail).not.toHaveBeenCalled();
});

test('a request without a body returns the required-email error',async()=>{
  const res=response();
  await resendVerification({},res,jest.fn());
  expect(res.code).toBe(400);
  expect(res.body).toEqual({message:'Email is required'});
  expect(rpc).not.toHaveBeenCalled();
});
