/**
 * Distance Provider Abstraction
 * 
 * Isolates geographic distance and travel time calculations from the core business logic.
 * Currently defaults to a Greedy Nearest-Neighbor Haversine heuristic to preserve speed,
 * but can easily be swapped with Google Maps, Mapbox, or OSRM implementations.
 */
import fetch from 'node-fetch';

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

  if (provider === 'tomtom') {
    const apiKey = process.env.TOMTOM_API_KEY;
    if (!apiKey) {
      console.warn('[Optimization] TOMTOM_API_KEY missing, falling back to haversine');
      return getDistanceAndDuration(lat1, lon1, lat2, lon2, 'haversine');
    }
    
    try {
      // TomTom Routing API (sync, with live traffic)
      // Note: TomTom expects longitude,latitude pairs!
      const url = `https://api.tomtom.com/routing/1/calculateRoute/${lat1},${lon1}:${lat2},${lon2}/json?key=${apiKey}&traffic=true`;
      
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`TomTom API Error: ${response.statusText}`);
      }
      
      const data = await response.json();
      const route = data.routes?.[0]?.summary;
      
      if (!route) {
        throw new Error('No route found from TomTom');
      }

      return {
        distance_meters: route.lengthInMeters,
        duration_min: Math.round((route.travelTimeInSeconds / 60) * 10) / 10
      };
    } catch (err) {
      console.error('[Optimization] TomTom Routing Failed:', err.message, '- falling back to haversine');
      return getDistanceAndDuration(lat1, lon1, lat2, lon2, 'haversine');
    }
  }

  // Future implementations (e.g., Google Maps Distance Matrix API) can be added here
  throw new Error(`Unsupported distance provider: ${provider}`);
}
