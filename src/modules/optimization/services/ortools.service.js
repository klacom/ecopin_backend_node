import fetch from 'node-fetch';

/**
 * Sends a distance matrix to the Python OR-Tools microservice to solve the Vehicle Routing Problem.
 * @param {Array<Array<number>>} distanceMatrix 
 * @param {number} numVehicles 
 * @returns {Promise<Array<Array<number>>>} Returns an array of node indices for each vehicle route.
 */
export async function solveVRPWithOrTools(distanceMatrix, numVehicles) {
  try {
    const payload = {
      distance_matrix: distanceMatrix,
      num_vehicles: numVehicles,
      depot: 0
    };

    const vrpUrl = process.env.VRP_SERVICE_URL || 'http://127.0.0.1:8003/solve_vrp';
    const response = await fetch(vrpUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(`OR-Tools service failed: ${response.statusText} - ${text}`);
    }

    const data = await response.json();
    return data.routes;
  } catch (err) {
    console.error('[Optimization] Failed to solve VRP via OR-Tools microservice:', err);
    throw err;
  }
}
