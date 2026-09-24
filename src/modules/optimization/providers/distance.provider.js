/**
 * Distance Provider Abstraction
 * 
 * Isolates geographic distance and travel time calculations from the core business logic.
 * Currently defaults to a Greedy Nearest-Neighbor Haversine heuristic to preserve speed,
 * but can easily be swapped with Google Maps, Mapbox, or OSRM implementations.
 */

// Haversine distance in meters
function haversineDistance(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const phi1 = lat1 * Math.PI / 180;
  const phi2 = lat2 * Math.PI / 180;
  const deltaPhi = (lat2 - lat1) * Math.PI / 180;
  const deltaLam = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(deltaPhi/2)**2 + Math.cos(phi1) * Math.cos(phi2) * Math.sin(deltaLam/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
}

/**
 * Calculates distance and estimated travel time between two geographic coordinates.
 * @param {number} lat1 
 * @param {number} lon1 
 * @param {number} lat2 
 * @param {number} lon2 
 * @param {string} provider - 'haversine' (default), 'google', 'mapbox', etc.
 * @returns {Promise<{distance_meters: number, duration_min: number}>}
 */
export async function getDistanceAndDuration(lat1, lon1, lat2, lon2, provider = 'haversine') {
  if (provider === 'haversine') {
    const distance_meters = haversineDistance(lat1, lon1, lat2, lon2);
    // Assume average speed of ~50 km/h (833 m/min) for urban environments
    const duration_min = distance_meters / 833;
    
    return {
      distance_meters,
      duration_min
    };
  }

  // Future implementations (e.g., Google Maps Distance Matrix API) can be added here
  throw new Error(`Unsupported distance provider: ${provider}`);
}
