// A citizen's visual hint is never a source for GIS coordinates or barangay assignment.
export function normalizeCitizenLandmark(value) {
    if (value === undefined || value === null) return null;
    if (typeof value !== 'string' || Array.from(value).length > 300) {
        throw Object.assign(new Error('Citizen landmark must be text of at most 300 characters.'), {statusCode:400});
    }
    return value.trim() || null;
}
