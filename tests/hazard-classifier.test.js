import { classifyReportHazard } from '../src/services/hazard-classifier.service.js';

describe('contextual hazard classification', () => {
  test.each([
    ['chemical spill on the road', 'hazmat_required'],
    ['discarded medical needles', 'hazmat_required'],
    ['possible gas smell near bins', 'suspected_hazard'],
    ['There are no chemical spills, just regular trash', 'standard'],
    ['A box of medical masks is on the sidewalk', 'standard'],
    ['large fallen tree blocking the road', 'standard'],
  ])('%s => %s', (title, expected) => {
    const result = classifyReportHazard({ issue_type: 'waste', title });
    expect(result.hazard_class).toBe(expected);
    expect(result.hazard_model_version).toBeTruthy();
    expect(result.hazard_confidence).toBeGreaterThan(0);
    expect(result.hazard_decision_source).toBe('contextual_rules');
  });
  test('uses issue type and notes together', () => {
    expect(classifyReportHazard({issue_type:'pollution', notes:'unidentified liquid by drain'}).hazard_class)
      .toBe('suspected_hazard');
  });
});
