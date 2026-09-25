import fetch from 'node-fetch';

/**
 * Calls TomTom Matrix Routing v2 API
 * @param {Array<{lat: number, lng: number}>} coordinates - Array of coordinates (Index 0 is depot)
 * @returns {Promise<Array<Array<number>>>} A 2D matrix of travel times in seconds
 */
export async function getTomTomDistanceMatrix(coordinates) {
  const apiKey = process.env.TOMTOM_API_KEY;
  if (!apiKey) throw new Error("TOMTOM_API_KEY is missing");

  // Construct points
  const points = coordinates.map(c => ({
    point: { latitude: c.lat, longitude: c.lng }
  }));

  const payload = {
    origins: points,
    destinations: points,
    options: {
      traffic: "live"
    }
  };

  const url = `https://api.tomtom.com/routing/matrix/2?key=${apiKey}`;
  
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`TomTom Matrix API failed: ${response.statusText} - ${errText}`);
  }

  const data = await response.json();
  
  // Parse response into a 2D array
  // TomTom returns matrix[originIndex][destinationIndex] = { routeSummary: { travelTimeInSeconds, ... } }
  const matrix = [];
  
  // Matrix Routing v2 actually returns: { "data": [ { "originIndex": 0, "destinationIndex": 0, "routeSummary": { "travelTimeInSeconds": 0 } }, ... ] }
  // Let's initialize a 2D array with 0s
  const size = coordinates.length;
  for (let i = 0; i < size; i++) {
    matrix.push(new Array(size).fill(0));
  }
  
  for (const result of data.data || []) {
    if (result.routeSummary && result.routeSummary.travelTimeInSeconds !== undefined) {
      matrix[result.originIndex][result.destinationIndex] = result.routeSummary.travelTimeInSeconds;
    }
  }

  return matrix;
}
