import { jest } from '@jest/globals';
const rpc = jest.fn();
const sendMail = jest.fn();
const from = jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabase: {}, supabaseAdmin: { rpc, from } }));
jest.unstable_mockModule('../src/config/email.config.js', () => ({ transporter: { sendMail } }));
jest.unstable_mockModule('../src/config/index.js', () => ({
    SMTP_FROM_NAME: 'EcoPin', SMTP_USER: 'sender@example.invalid',
    APP_BASE_URL: 'https://backend.example.invalid', EMAIL_VERIFICATION_EXPIRY_HOURS: 24,
    MOBILE_REDIRECT_URL: 'ecopin://auth'
}));
const { generateVerificationToken, sendVerificationEmail } = await import('../src/services/email.service.js');
const { resendVerification, verifyEmail } = await import('../src/controllers/auth.controller.js');
const { renderVerificationHtml } = await import('../src/services/verification-template.service.js');
beforeEach(() => { jest.resetAllMocks(); });
test('issuance without an email binding fails before any database call', async () => {
    await expect(generateVerificationToken('user-id')).rejects.toThrow('binding is required');
    expect(rpc).not.toHaveBeenCalled();
});
test('missing binding migration fails closed instead of issuing an unusable unbound token', async () => {
    rpc.mockResolvedValueOnce({ error: { code: 'PGRST202', message: 'missing p_email' } })
        .mockResolvedValueOnce({ data: 'issuance-id', error: null });
    await expect(generateVerificationToken('user-id', 'Citizen@Example.invalid')).rejects.toThrow();
    expect(rpc).toHaveBeenCalledTimes(1);
});
test('resend looks up the account, issues a bound token, and delivers the email', async () => {
    rpc.mockResolvedValueOnce({ data: 'user-id', error: null }).mockResolvedValueOnce({ data: 'issuance-id', error: null });
    sendMail.mockResolvedValue({ messageId: 'synthetic' });
    const res = { status: jest.fn().mockReturnThis(), json: jest.fn() };
    await resendVerification({ body: { email: ' Citizen@Example.invalid ' } }, res);
    expect(rpc).toHaveBeenNthCalledWith(1, 'find_email_verification_user', { p_email: 'citizen@example.invalid' });
    expect(sendMail).toHaveBeenCalledTimes(1);
    expect(sendMail.mock.calls[0][0].to).toBe('citizen@example.invalid');
    expect(res.status).toHaveBeenCalledWith(200);
});
test('verification redeems only the email-bound token through the atomic RPC', async () => {
    const maybeSingle = jest.fn().mockResolvedValue({ data: {
        id: 'issuance-id', user_id: 'user-id', issued_to_email: 'citizen@example.invalid', used_at: null
    }, error: null });
    from.mockReturnValue({ select: () => ({ eq: () => ({ maybeSingle }) }) });
    // Auth identity is authoritative, never taken from the browser.
    const { supabaseAdmin } = await import('../src/config/supabase.config.js');
    supabaseAdmin.auth = { admin: { getUserById: jest.fn().mockResolvedValue({ data: { user: { id: 'user-id', email: 'citizen@example.invalid' } } }) } };
    rpc.mockResolvedValue({ data: true, error: null });
    const res = { set: jest.fn(), status: jest.fn().mockReturnThis(), send: jest.fn() };
    await verifyEmail({ query: { token: '00000000-0000-4000-8000-000000000001' } }, res);
    expect(rpc).toHaveBeenCalledWith('redeem_email_verification_atomic', {
        p_verification_id: 'issuance-id', p_user_id: 'user-id', p_expected_email: 'citizen@example.invalid'
    });
    expect(res.status).toHaveBeenCalledWith(200);
    expect(res.send.mock.calls[0][0]).toContain('Your email is verified');
});
test('result pages escape messages, support dark mode, and provide honest recovery', () => {
    const html = renderVerificationHtml('<script>unsafe</script>', false);
    expect(html).toContain('&lt;script&gt;');
    expect(html).not.toContain('<script>');
    expect(html).toContain('prefers-color-scheme:dark');
    expect(html).toContain('Resend verification email');
    expect(html).not.toContain('ecopin://auth/verified');
});
test('issuance binds normalized email and sends only a digest to the database', async () => {
    rpc.mockResolvedValue({ data: 'issuance-id', error: null });
    const token = await generateVerificationToken('user-id', ' Citizen@Example.invalid ');
    expect(rpc).toHaveBeenCalledWith('issue_email_verification', expect.objectContaining({
        p_email: 'citizen@example.invalid', p_token_digest: expect.stringMatching(/^[a-f0-9]{64}$/)
    }));
    expect(JSON.stringify(rpc.mock.calls)).not.toContain(token);
});
test('cooldown does not send an email without an issued token', async () => {
    rpc.mockResolvedValue({ data: null, error: null });
    expect(await generateVerificationToken('user-id', 'citizen@example.invalid')).toBeNull();
});
test('verification email uses HTTPS civic-blue markup, expiry, and plain text fallback', async () => {
    sendMail.mockResolvedValue({ messageId: 'synthetic' });
    await sendVerificationEmail('citizen@example.invalid', 'synthetic-token');
    const email = sendMail.mock.calls[0][0];
    expect(email.html).toContain('#0052CC');
    expect(email.html).toContain('24 hours');
    expect(email.html).toContain('https://backend.example.invalid/api/auth/verify-email?token=synthetic-token');
    expect(email.html).not.toContain('#457113');
    expect(email.text).toContain('https://backend.example.invalid/api/auth/verify-email');
});
