/**
 * Applies traffic simulation multiplier to route time estimates
 * @param {Array<Object>} routeWaypoints - Array of waypoints
 * @param {string} trafficCondition - 'low', 'moderate', 'heavy'
 * @returns {Object} { adjustedWaypoints, simulation }
 */
export function applyTrafficSimulation(routeWaypoints, trafficCondition) {
  const multipliers = {
    low: 1.0,
    moderate: 1.3,
    heavy: 1.8
  };
  
  const multiplier = multipliers[trafficCondition] || 1.0;

  const adjustedWaypoints = routeWaypoints.map(wp => ({
    ...wp,
    estimated_time_from_previous_min: wp.estimated_time_from_previous_min !== undefined
      ? Math.round(wp.estimated_time_from_previous_min * multiplier * 10) / 10
      : null,
  }));

  const labels = {
    low: 'SIMULATED — Low Traffic',
    moderate: 'SIMULATED — Moderate Traffic',
    heavy: 'SIMULATED — Heavy Traffic',
  };

  return {
    adjustedWaypoints,
    simulation: {
      condition: trafficCondition,
      label: labels[trafficCondition] || 'SIMULATED'
    }
  };
}
