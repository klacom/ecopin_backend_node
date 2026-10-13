import { jest } from '@jest/globals';

const mockGetUser = jest.fn();
const mockProfileSelect = jest.fn();

jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabase: {
    auth: {
      getUser: mockGetUser
    }
  },
  supabaseAdmin: {
    from: () => ({
      select: () => ({
        eq: () => ({
          single: mockProfileSelect
        })
      })
    })
  }
}));

const { authenticate, optionalAuthenticate } = await import('../src/middleware/auth.middleware.js');
const { clearAuthCache } = await import('../src/services/auth-cache.service.js');

describe('Auth Middleware Caching Integration', () => {
  beforeEach(() => {
    clearAuthCache();
    mockGetUser.mockReset();
    mockProfileSelect.mockReset();
  });

  test('authenticate uses in-memory cache for consecutive requests with the same token', async () => {
    mockGetUser.mockResolvedValue({ data: { user: { id: 'usr-123' } }, error: null });
    mockProfileSelect.mockResolvedValue({ data: { role: 'officer', full_name: 'Test Officer' }, error: null });

    const req1 = { headers: { authorization: 'Bearer test-token-xyz' } };
    const res1 = { status: jest.fn().mockReturnThis(), json: jest.fn() };
    const next1 = jest.fn();

    // First request: Cache Miss -> calls Supabase Auth and Profiles
    await authenticate(req1, res1, next1);
    expect(next1).toHaveBeenCalled();
    expect(mockGetUser).toHaveBeenCalledTimes(1);
    expect(mockProfileSelect).toHaveBeenCalledTimes(1);
    expect(req1.user).toMatchObject({ id: 'usr-123', role: 'officer', full_name: 'Test Officer' });

    // Second request: Cache Hit -> skips Supabase entirely!
    const req2 = { headers: { authorization: 'Bearer test-token-xyz' } };
    const res2 = { status: jest.fn().mockReturnThis(), json: jest.fn() };
    const next2 = jest.fn();

    await authenticate(req2, res2, next2);
    expect(next2).toHaveBeenCalled();
    expect(mockGetUser).toHaveBeenCalledTimes(1); // STILL 1!
    expect(mockProfileSelect).toHaveBeenCalledTimes(1); // STILL 1!
    expect(req2.user).toMatchObject({ id: 'usr-123', role: 'officer', full_name: 'Test Officer' });
  });

  test('optionalAuthenticate uses cache and attaches user without querying Supabase again', async () => {
    mockGetUser.mockResolvedValue({ data: { user: { id: 'usr-456' } }, error: null });
    mockProfileSelect.mockResolvedValue({ data: { role: 'citizen', full_name: 'Citizen Jane' }, error: null });

    const req1 = { headers: { authorization: 'Bearer opt-token-123' } };
    const next1 = jest.fn();
    await optionalAuthenticate(req1, {}, next1);
    expect(next1).toHaveBeenCalled();
    expect(mockGetUser).toHaveBeenCalledTimes(1);

    const req2 = { headers: { authorization: 'Bearer opt-token-123' } };
    const next2 = jest.fn();
    await optionalAuthenticate(req2, {}, next2);
    expect(next2).toHaveBeenCalled();
    expect(mockGetUser).toHaveBeenCalledTimes(1); // Cache hit!
    expect(req2.user.id).toBe('usr-456');
  });
});
