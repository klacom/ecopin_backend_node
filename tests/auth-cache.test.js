import { jest } from '@jest/globals';
import { getCachedUser, setCachedUser, invalidateToken, clearAuthCache, getAuthCacheSize } from '../src/services/auth-cache.service.js';

describe('Auth Cache Service', () => {
  beforeEach(() => {
    clearAuthCache();
  });

  test('returns null for uncached token', () => {
    expect(getCachedUser('non-existent-token')).toBeNull();
  });

  test('stores and retrieves cached user safely as a cloned object', () => {
    const user = { id: 'user-1', email: 'test@example.com', role: 'officer' };
    setCachedUser('valid-token-123', user);

    const retrieved = getCachedUser('valid-token-123');
    expect(retrieved).toEqual(user);

    // Modifying retrieved object does not mutate the cached entry
    retrieved.role = 'tampered';
    expect(getCachedUser('valid-token-123').role).toBe('officer');
  });

  test('expires entries when TTL elapsed', async () => {
    const user = { id: 'user-2', email: 'short@example.com', role: 'citizen' };
    setCachedUser('expiring-token', user, 20); // 20ms TTL

    expect(getCachedUser('expiring-token')).toEqual(user);
    await new Promise(resolve => setTimeout(resolve, 30));
    expect(getCachedUser('expiring-token')).toBeNull();
  });

  test('invalidates specific token correctly', () => {
    const user = { id: 'user-3', role: 'admin' };
    setCachedUser('logout-token', user);
    expect(getCachedUser('logout-token')).not.toBeNull();

    invalidateToken('logout-token');
    expect(getCachedUser('logout-token')).toBeNull();
  });

  test('clearAuthCache purges all entries', () => {
    setCachedUser('t1', { id: '1' });
    setCachedUser('t2', { id: '2' });
    expect(getAuthCacheSize()).toBe(2);

    clearAuthCache();
    expect(getAuthCacheSize()).toBe(0);
  });
});
