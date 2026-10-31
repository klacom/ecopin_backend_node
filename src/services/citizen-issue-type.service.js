// Citizen-chosen concern category (optional hint; AI classification may still refine it)
export const CITIZEN_ISSUE_TYPES = ['waste', 'flooding', 'pollution', 'infrastructure', 'illegal_logging', 'others'];
export const normalizeCitizenIssueType = (value) => {
    const key = String(value ?? '').trim().toLowerCase().replace(/[\s-]+/g, '_');
    return CITIZEN_ISSUE_TYPES.includes(key) ? key : null;
};
