/**
 * Applies weather simulation factors to cluster priorities
 * @param {Array<Object>} clusters - Array of prioritized clusters
 * @param {string} weatherCondition - 'normal', 'heavy_rain', 'storm'
 * @returns {Object} { adjustedClusters, simulation }
 */
export function applyWeatherSimulation(clusters, weatherCondition) {
  if (weatherCondition === 'normal') {
    return {
      adjustedClusters: clusters,
      simulation: {
        condition: 'normal',
        label: 'SIMULATED — Normal Weather'
      }
    };
  }

  // The actual scoring was done in mcdaPrioritizer, but we return the label here for the response payload
  const labels = {
    heavy_rain: 'SIMULATED — Heavy Rain',
    storm: 'SIMULATED — Storm',
  };

  return {
    adjustedClusters: clusters,
    simulation: {
      condition: weatherCondition,
      label: labels[weatherCondition] || 'SIMULATED'
    }
  };
}
