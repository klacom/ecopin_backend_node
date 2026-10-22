// Context rules are deliberately conservative: ordinary debris remains in the
// normal dispatch pool, while explicit hazardous material needs specialist triage.
export const HAZARD_CLASSIFIER_VERSION = 'context-rules-v2';

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
const uncertainty = /\b(?:not sure|unsure|uncertain|maybe|possibly|possible|might|could be)\b/i;
const ambiguousClinicalMaterial = /\b(?:medical|hospital|clinical)\s+masks?\b/i;

function cueContext(text, expression) {
  for (const match of text.matchAll(new RegExp(expression.source, 'gi'))) {
    // Only nearby negation can negate a cue. A prior sentence cannot.
    const sentenceStart = Math.max(text.lastIndexOf('.', match.index - 1),
      text.lastIndexOf('!', match.index - 1), text.lastIndexOf('?', match.index - 1)) + 1;
    const preceding = text.slice(Math.max(sentenceStart, match.index - 45), match.index);
    const words = preceding.trim().split(/\s+/);
    if (uncertainty.test(words.slice(-8).join(' '))) return 'uncertain';
    if (!negation.test(words.slice(-5).join(' '))) return 'asserted';
  }
  return null;
}

export function classifyReportHazard({ issue_type, title, description, notes } = {}) {
  const text = [title, description, notes].filter(Boolean).join('. ');
  const issue = String(issue_type ?? '').toLowerCase();
  let hazardClass = 'standard';
  let confidence = 0.8;
  const explicitContexts = explicitHazards.map((cue) => cueContext(text, cue));
  if (explicitContexts.includes('asserted')) {
    hazardClass = 'hazmat_required';
    confidence = 0.96;
  } else if (explicitContexts.includes('uncertain') ||
      uncertainHazards.some((cue) => cueContext(text, cue) != null)) {
    hazardClass = 'suspected_hazard';
    confidence = 0.78;
  } else if (issue === 'pollution' && /\b(?:unknown substance|unidentified liquid|unidentified powder)\b/i.test(text)) {
    hazardClass = 'suspected_hazard';
    confidence = 0.68;
  } else if (ambiguousClinicalMaterial.test(text) &&
      !/\b(?:unused|new|unopened|household)\b/i.test(text)) {
    // Masks alone do not establish contamination or justify an emergency hold.
    hazardClass = 'unknown';
    confidence = 0.45;
  }
  return {
    hazard_class: hazardClass,
    hazard_model_version: HAZARD_CLASSIFIER_VERSION,
    hazard_confidence: confidence,
    hazard_decision_source: 'contextual_rules',
    hazard_classified_at: new Date().toISOString(),
  };
}
