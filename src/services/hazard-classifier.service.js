// Context rules are deliberately conservative: ordinary debris remains in the
// normal dispatch pool, while explicit hazardous material needs specialist triage.
export const HAZARD_CLASSIFIER_VERSION = 'context-rules-v1';

const explicitHazards = [
  /\b(?:chemical|acid|pesticide|solvent|fuel|oil)\s+(?:spills?|leaks?|drums?|containers?|waste)\b/i,
  /\b(?:toxic|radioactive|asbestos|mercury|biohazard(?:ous)?)\b/i,
  /\b(?:medical|hospital|clinical)\s+(?:waste|sharps|needles|syringes)\b/i,
  /\b(?:used|discarded)\s+(?:needles|syringes)\b/i,
];
const uncertainHazards = [
  /\b(?:chemical|gas|pesticide)\s+(?:odor|odour|smell|fumes?)\b/i,
  /\b(?:unknown|unmarked)\s+(?:drums?|containers?)\b/i,
];
const negation = /\b(?:no|not|without|none|never|unlikely|absent)\b/i;

function asserted(text, expression) {
  for (const match of text.matchAll(new RegExp(expression.source, 'gi'))) {
    // Only nearby negation can negate a cue. A prior sentence cannot.
    const sentenceStart = Math.max(text.lastIndexOf('.', match.index - 1),
      text.lastIndexOf('!', match.index - 1), text.lastIndexOf('?', match.index - 1)) + 1;
    const preceding = text.slice(Math.max(sentenceStart, match.index - 45), match.index);
    const lastWords = preceding.trim().split(/\s+/).slice(-5).join(' ');
    if (!negation.test(lastWords)) return true;
  }
  return false;
}

export function classifyReportHazard({ issue_type, title, description, notes } = {}) {
  const text = [title, description, notes].filter(Boolean).join('. ');
  const issue = String(issue_type ?? '').toLowerCase();
  let hazardClass = 'standard';
  let confidence = 0.8;
  if (explicitHazards.some((cue) => asserted(text, cue))) {
    hazardClass = 'hazmat_required';
    confidence = 0.96;
  } else if (uncertainHazards.some((cue) => asserted(text, cue))) {
    hazardClass = 'suspected_hazard';
    confidence = 0.78;
  } else if (issue === 'pollution' && /\b(?:unknown substance|unidentified liquid|unidentified powder)\b/i.test(text)) {
    hazardClass = 'suspected_hazard';
    confidence = 0.68;
  }
  return {
    hazard_class: hazardClass,
    hazard_model_version: HAZARD_CLASSIFIER_VERSION,
    hazard_confidence: confidence,
    hazard_decision_source: 'contextual_rules',
    hazard_classified_at: new Date().toISOString(),
  };
}
