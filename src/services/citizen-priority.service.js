const REASONS = new Set([
  'community_event', 'school_hospital_zone', 'severe_obstruction', 'public_health_hazard',
]);

// Citizen urgency is a request for officer review, never an approved dispatch priority.
export function citizenPriorityFields(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new Error('Report details must be an object.');
  }
  const { citizen_priority, priority_reason, priority_explanation } = input;
  if (citizen_priority === undefined || citizen_priority === null) {
    if (priority_reason != null || priority_explanation != null) {
      throw new Error('Choose Urgent or Non-urgent before adding a priority reason.');
    }
    return {}; // Preserve submissions from older clients and queued reports.
  }
  if (!['urgent', 'non_urgent'].includes(citizen_priority)) {
    throw new Error('Priority must be Urgent or Non-urgent.');
  }
  if (citizen_priority === 'non_urgent') {
    return { citizen_priority, priority_reason: null, priority_explanation: null };
  }
  if (!REASONS.has(priority_reason)) {
    throw new Error('Choose a preset reason for urgent review.');
  }
  if (priority_explanation != null && (typeof priority_explanation !== 'string' || priority_explanation.length > 1000)) {
    throw new Error('Priority explanation must be text of up to 1000 characters.');
  }
  return { citizen_priority, priority_reason, priority_explanation: priority_explanation?.trim() || null };
}
