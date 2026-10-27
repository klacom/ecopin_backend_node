import { getCurrentSystemSettings } from './system-settings.service.js';

export const DEFAULT_PASSWORD_POLICY = {
    password_min_length: 8,
    password_require_uppercase: true,
    password_require_lowercase: true,
    password_require_numbers: true,
    password_require_special_chars: true
};
const invalid = message => Object.assign(new Error(message), { statusCode: 400 });

export function validatePasswordSettings(settings) {
    if (settings.password_min_length !== undefined && (!Number.isInteger(settings.password_min_length) || settings.password_min_length < 6 || settings.password_min_length > 32)) throw invalid('Minimum password length must be an integer from 6 to 32.');
    for (const key of Object.keys(DEFAULT_PASSWORD_POLICY).filter(key => key !== 'password_min_length')) {
        if (settings[key] !== undefined && typeof settings[key] !== 'boolean') throw invalid('Password requirement switches must be true or false.');
    }
}

export async function getPasswordPolicy(client) {
    const { data, error } = await getCurrentSystemSettings(client, Object.keys(DEFAULT_PASSWORD_POLICY).join(','));
    if (error) throw Object.assign(new Error('Password policy could not load. Please try again.'), { statusCode: 503 });
    const policy = { ...DEFAULT_PASSWORD_POLICY, ...(data || {}) };
    validatePasswordSettings(policy);
    return policy;
}

export async function assertPasswordPolicy(password, client) {
    const policy = await getPasswordPolicy(client);
    if (typeof password !== 'string' || password.length < policy.password_min_length) throw invalid(`Password must contain at least ${policy.password_min_length} characters.`);
    for (const [key, expression, description] of [
        ['password_require_uppercase', /[A-Z]/, 'an uppercase letter'],
        ['password_require_lowercase', /[a-z]/, 'a lowercase letter'],
        ['password_require_numbers', /[0-9]/, 'a number'],
        ['password_require_special_chars', /[!@#$%^&*(),.?":{}|<>]/, 'a special character']
    ]) {
        if (policy[key] && !expression.test(password)) throw invalid(`Password must contain ${description}.`);
    }
}
