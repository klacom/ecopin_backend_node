import {jest} from '@jest/globals';
import {assertSupabaseIsolation} from '../src/config/data-isolation.js';

const production = 'https://wcruoyygungqxazdwhtv.supabase.co';
const check = (url, env = {}) => () => assertSupabaseIsolation(url, env);

test.each(['development', 'test', 'preview', 'staging', undefined])(
  '%s refuses production even when explicitly listed as development', NODE_ENV => {
    expect(check(production, {NODE_ENV, DEVELOPMENT_SUPABASE_URL: production})).toThrow(/production/i);
  }
);
test('NODE_ENV=production alone does not authorize a local production writer', () => {
  expect(check(production, {NODE_ENV: 'production'})).toThrow(/production/i);
});
test('production deployment requires both explicit production markers', () => {
  expect(check(production, {NODE_ENV: 'production', DEPLOYMENT_ENV: 'production'})).not.toThrow();
  expect(check(production, {NODE_ENV: 'development', DEPLOYMENT_ENV: 'production'})).toThrow();
});
test.each(['http://127.0.0.1:54321', 'http://localhost:54321', 'http://[::1]:54321'])('permits isolated loopback %s', url => {
  expect(check(url)).not.toThrow();
});
test('hosted development must match the separately designated non-production origin', () => {
  const url = 'https://synthetic-development.supabase.co';
  expect(check(url)).toThrow(/development/i);
  expect(check(url, {DEVELOPMENT_SUPABASE_URL: url})).not.toThrow();
  expect(check(url, {DEVELOPMENT_SUPABASE_URL: 'https://other.supabase.co'})).toThrow();
});
test.each([undefined, '', 'not-a-url', 'ftp://localhost:54321', 'http://localhost.evil.test',
  'https://user:password@localhost:54321', 'http://localhost:54321/rest/v1',
  'http://localhost:54321/?token=private', 'http://localhost:54321/#private'])('rejects malformed or misleading target %s', url => {
  expect(check(url)).toThrow();
});
test('rejects unencrypted hosted development and keeps credentials out of errors', () => {
  const url = 'http://synthetic-development.supabase.co';
  expect(check(url, {DEVELOPMENT_SUPABASE_URL: url})).toThrow();
  try { assertSupabaseIsolation('https://user:private-value@localhost'); }
  catch (error) { expect(error.message).not.toContain('private-value'); }
});
test('the shared client boundary refuses production before constructing either client', async () => {
  const createClient = jest.fn();
  jest.unstable_mockModule('@supabase/supabase-js', () => ({createClient}));
  jest.unstable_mockModule('../src/config/index.js', () => ({
    NEXT_PUBLIC_SUPABASE_URL: production, SUPABASE_SECRET_KEY: 'test-secret',
    SUPABASE_SERVICE_ROLE_KEY: '', SUPABASE_PUBLISHABLE_KEY: 'test-public', SUPABASE_ANON_KEY: ''
  }));
  const previous = process.env.DEPLOYMENT_ENV;
  delete process.env.DEPLOYMENT_ENV;
  try {
    await expect(import('../src/config/supabase.config.js')).rejects.toThrow(/production/i);
    expect(createClient).not.toHaveBeenCalled();
  } finally {
    if (previous === undefined) delete process.env.DEPLOYMENT_ENV;
    else process.env.DEPLOYMENT_ENV = previous;
  }
});
