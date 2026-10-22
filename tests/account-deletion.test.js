import { jest } from '@jest/globals';

// Set up mock references
const mockSupabaseAdmin = {
  from: jest.fn(),
  auth: {
    admin: {
      deleteUser: jest.fn(),
      signOut: jest.fn(),
    },
  },
};

const mockSupabase = {
  auth: {
    signInWithPassword: jest.fn(),
  },
};

const mockInvalidateToken = jest.fn();

// Mock dependencies before importing controller
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabase: mockSupabase,
  supabaseAdmin: mockSupabaseAdmin,
}));

jest.unstable_mockModule('../src/services/email.service.js', () => ({
  generateVerificationToken: jest.fn(),
  sendVerificationEmail: jest.fn(),
}));

jest.unstable_mockModule('../src/services/auth-cache.service.js', () => ({
  invalidateToken: mockInvalidateToken,
  getCachedUser: jest.fn(),
  setCachedUser: jest.fn(),
}));

const { deleteAccount } = await import('../src/controllers/auth.controller.js');

describe('WT-89: Citizen Account Deletion Flow (Google Play Policy Compliance)', () => {
  let req;
  let res;
  let next;

  beforeEach(() => {
    jest.resetAllMocks();
    mockSupabaseAdmin.auth.admin.signOut.mockResolvedValue({ error: null });
    res = {
      status: jest.fn().mockReturnThis(),
      json: jest.fn().mockReturnThis(),
    };
    next = jest.fn();
  });

  describe('Unauthenticated Request Validation', () => {
    test('returns 400 when neither token nor credentials are provided', async () => {
      req = {
        headers: {},
        body: { confirmation: 'I confirm' },
      };

      await deleteAccount(req, res, next);

      expect(res.status).toHaveBeenCalledWith(400);
      expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
        error: 'Missing credentials',
      }));
    });

    test('returns 401 when email and password verification fails', async () => {
      req = {
        headers: {},
        body: {
          email: 'citizen@example.com',
          password: 'wrongpassword',
        },
      };

      mockSupabase.auth.signInWithPassword.mockResolvedValueOnce({
        data: null,
        error: { message: 'Invalid login credentials' },
      });

      await deleteAccount(req, res, next);

      expect(mockSupabase.auth.signInWithPassword).toHaveBeenCalledWith({
        email: 'citizen@example.com',
        password: 'wrongpassword',
      });
      expect(res.status).toHaveBeenCalledWith(401);
      expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
        message: 'Invalid email or password.',
      }));
    });
  });

  describe('Role Authorization Guard', () => {
    test('rejects staff or officer account deletion with 403', async () => {
      req = {
        user: { id: 'officer-uuid-123' },
        headers: { authorization: 'Bearer officer-token' },
        body: { confirmation: 'I confirm' },
      };

      // Mock profiles lookup returning officer role
      mockSupabaseAdmin.from.mockReturnValueOnce({
        select: jest.fn().mockReturnValueOnce({
          eq: jest.fn().mockReturnValueOnce({
            maybeSingle: jest.fn().mockResolvedValueOnce({
              data: { id: 'officer-uuid-123', role: 'officer' },
              error: null,
            }),
          }),
        }),
      });

      await deleteAccount(req, res, next);

      expect(res.status).toHaveBeenCalledWith(403);
      expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
        error: 'Forbidden',
      }));
      // Reports and profiles must not be modified
      expect(mockSupabaseAdmin.from).not.toHaveBeenCalledWith('reports');
    });
  });

  describe('Deletion safeguards', () => {
    const profileResult = (data, error = null) => ({
      select: () => ({ eq: () => ({ maybeSingle: async () => ({ data, error }) }) }),
    });
    test.each(['admin', 'field_crew', 'officer', null, ''])('blocks role %s before any deletion', async (role) => {
      mockSupabaseAdmin.from.mockReturnValue(profileResult(role === null ? null : { role }));
      await deleteAccount({ user: { id: 'user' }, headers: {}, body: { confirmation: 'I confirm' } }, res, next);
      expect(res.status).toHaveBeenCalledWith(403);
      expect(mockSupabaseAdmin.auth.admin.deleteUser).not.toHaveBeenCalled();
      expect(mockSupabaseAdmin.auth.admin.signOut).not.toHaveBeenCalled();
    });
    test.each([undefined, '', 'i confirm', 'I confirm '])('requires exact confirmation %s', async (confirmation) => {
      mockSupabaseAdmin.from.mockReturnValue(profileResult({ role: 'citizen' }));
      await deleteAccount({ user: { id: 'user' }, headers: { authorization: 'Bearer token' }, body: { confirmation } }, res, next);
      expect(res.status).toHaveBeenCalledWith(400);
      expect(mockSupabaseAdmin.from).not.toHaveBeenCalledWith('reports');
    });
    test('profile lookup failure cannot fall back to citizen', async () => {
      mockSupabaseAdmin.from.mockReturnValue(profileResult(null, { message: 'unavailable' }));
      await deleteAccount({ user: { id: 'user' }, headers: {}, body: { confirmation: 'I confirm' } }, res, next);
      expect(res.status).toHaveBeenCalledWith(403);
      expect(mockSupabaseAdmin.auth.admin.signOut).not.toHaveBeenCalled();
    });
    test('post-logout failure tells the client to clear its session without claiming success', async () => {
      mockSupabaseAdmin.from.mockImplementation(table => table === 'profiles'
        ? profileResult({ role: 'citizen' })
        : { update: () => ({ eq: async () => ({ error: { message: 'unavailable' } }) }) });
      await deleteAccount({ user: { id: 'user' }, headers: { authorization: 'Bearer token' }, body: { confirmation: 'I confirm' } }, res, next);
      expect(res.status).toHaveBeenCalledWith(500);
      expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ signed_out: true }));
      expect(mockSupabaseAdmin.auth.admin.deleteUser).not.toHaveBeenCalled();
    });
    test('stops before changing data when session revocation fails', async () => {
      mockSupabaseAdmin.from.mockReturnValue(profileResult({ role: 'citizen' }));
      mockSupabaseAdmin.auth.admin.signOut.mockResolvedValue({ error: { message: 'unavailable' } });
      await deleteAccount({ user: { id: 'user' }, headers: { authorization: 'Bearer token' }, body: { confirmation: 'I confirm' } }, res, next);
      expect(res.status).toHaveBeenCalledWith(503);
      expect(mockSupabaseAdmin.from).not.toHaveBeenCalledWith('reports');
    });
  });

  describe('Successful Deletion & Waste Report Anonymization', () => {
    test('scrubs credentials and anonymizes reports for authenticated citizen', async () => {
      const citizenId = 'citizen-uuid-456';
      req = {
        user: { id: citizenId },
        headers: { authorization: 'Bearer citizen-token' },
        body: { confirmation: 'I confirm' },
        ip: '127.0.0.1',
        get: jest.fn().mockReturnValue('EcopinApp/1.0'),
      };

      // 1. Profile role check -> citizen
      const profileSelectMock = {
        select: jest.fn().mockReturnValue({
          eq: jest.fn().mockReturnValue({
            maybeSingle: jest.fn().mockResolvedValue({
              data: { id: citizenId, role: 'citizen' },
              error: null,
            }),
          }),
        }),
      };

      // 2. Anonymize reports
      const reportsUpdateMock = {
        update: jest.fn().mockReturnValue({
          eq: jest.fn().mockResolvedValue({ error: null }),
        }),
      };

      // 3. Delete profile
      const profileDeleteMock = {
        delete: jest.fn().mockReturnValue({
          eq: jest.fn().mockResolvedValue({ error: null }),
        }),
      };

      // 4. Audit log insert
      const auditLogMock = {
        insert: jest.fn().mockResolvedValue({ error: null }),
      };

      mockSupabaseAdmin.from.mockImplementation((table) => {
        if (table === 'profiles') {
          // Can be called for role check or deletion
          return {
            select: profileSelectMock.select,
            delete: profileDeleteMock.delete,
          };
        }
        if (table === 'reports') {
          return reportsUpdateMock;
        }
        if (table === 'system_logs') {
          return auditLogMock;
        }
        return {};
      });

      // 5. Auth admin delete
      mockSupabaseAdmin.auth.admin.deleteUser.mockResolvedValueOnce({ error: null });

      await deleteAccount(req, res, next);

      expect(mockSupabaseAdmin.auth.admin.signOut).toHaveBeenCalledWith('citizen-token', 'global');
      expect(mockSupabaseAdmin.auth.admin.signOut.mock.invocationCallOrder[0]).toBeLessThan(reportsUpdateMock.update.mock.invocationCallOrder[0]);
      // Verify report anonymization was executed: user_id = null
      expect(reportsUpdateMock.update).toHaveBeenCalledWith({ user_id: null });
      // Verify profile was deleted
      expect(profileDeleteMock.delete).toHaveBeenCalled();
      // Verify Supabase auth credentials were deleted
      expect(mockSupabaseAdmin.auth.admin.deleteUser).toHaveBeenCalledWith(citizenId);
      // Verify cache token was invalidated
      expect(mockInvalidateToken).toHaveBeenCalledWith('citizen-token', citizenId);

      // Verify 200 response
      expect(res.status).toHaveBeenCalledWith(200);
      expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
        success: true,
        message: expect.stringContaining('anonymized'),
      }));
    });

    test('successfully deletes account via email and password credentials from web', async () => {
      const citizenId = 'web-citizen-uuid-789';
      req = {
        headers: {},
        body: {
          email: 'citizen@pasig.gov',
          password: 'ValidPassword123!',
          confirmation: 'I confirm',
        },
        ip: '127.0.0.1',
        get: jest.fn().mockReturnValue('Mozilla/5.0'),
      };

      // Mock password sign-in
      mockSupabase.auth.signInWithPassword.mockResolvedValueOnce({
        data: {
          user: { id: citizenId, email: 'citizen@pasig.gov' },
          session: { access_token: 'web-token' },
        },
        error: null,
      });

      // Mock profile check
      const profileSelectMock = {
        select: jest.fn().mockReturnValue({
          eq: jest.fn().mockReturnValue({
            maybeSingle: jest.fn().mockResolvedValue({
              data: { id: citizenId, role: 'citizen' },
              error: null,
            }),
          }),
        }),
      };

      const reportsUpdateMock = {
        update: jest.fn().mockReturnValue({
          eq: jest.fn().mockResolvedValue({ error: null }),
        }),
      };

      const profileDeleteMock = {
        delete: jest.fn().mockReturnValue({
          eq: jest.fn().mockResolvedValue({ error: null }),
        }),
      };

      mockSupabaseAdmin.from.mockImplementation((table) => {
        if (table === 'profiles') {
          return {
            select: profileSelectMock.select,
            delete: profileDeleteMock.delete,
          };
        }
        if (table === 'reports') {
          return reportsUpdateMock;
        }
        if (table === 'system_logs') {
          return { insert: jest.fn().mockResolvedValue({ error: null }) };
        }
        return {};
      });

      mockSupabaseAdmin.auth.admin.deleteUser.mockResolvedValueOnce({ error: null });

      await deleteAccount(req, res, next);

      expect(mockSupabase.auth.signInWithPassword).toHaveBeenCalledWith({
        email: 'citizen@pasig.gov',
        password: 'ValidPassword123!',
      });
      expect(reportsUpdateMock.update).toHaveBeenCalledWith({ user_id: null });
      expect(mockSupabaseAdmin.auth.admin.deleteUser).toHaveBeenCalledWith(citizenId);
      expect(res.status).toHaveBeenCalledWith(200);
      expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
    });
  });
});
