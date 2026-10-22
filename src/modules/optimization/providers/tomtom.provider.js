import fetch from 'node-fetch';

const BASE = 'https://api.tomtom.com/routing/matrix/2';
const ASYNC_TILE_SIDE = 50; // 50 × 50 = TomTom's standard 2,500-cell async limit.

function rows(size) { return Array.from({ length: size }, () => Array(size).fill(null)); }
function points(coordinates) { return coordinates.map(({ lat, lng }) => ({ point: { latitude: lat, longitude: lng } })); }
function copyCells(result, matrix, rowOffset, columnOffset, rowCount, columnCount) {
  if (!Array.isArray(result?.data)) throw new Error('TomTom Matrix returned no route cells');
  for (const cell of result.data) {
    const { originIndex, destinationIndex } = cell;
    const duration = cell.routeSummary?.travelTimeInSeconds;
    if (!Number.isInteger(originIndex) || !Number.isInteger(destinationIndex) ||
      originIndex < 0 || originIndex >= rowCount || destinationIndex < 0 || destinationIndex >= columnCount ||
      !Number.isFinite(duration) || duration < 0) throw new Error('TomTom Matrix returned an invalid route cell');
    const row = rowOffset + originIndex, column = columnOffset + destinationIndex;
    if (matrix[row][column] !== null) throw new Error('TomTom Matrix duplicated a route cell');
    matrix[row][column] = duration;
  }
}

async function responseJson(response, stage) {
  if (!response.ok) throw new Error(`TomTom Matrix ${stage} returned HTTP ${response.status}`);
  return response.json();
}

function pause(ms, signal) {
  return new Promise((resolve, reject) => {
    const onAbort = () => { clearTimeout(timer); reject(signal.reason); };
    const timer = setTimeout(() => { signal.removeEventListener('abort', onAbort); resolve(); }, ms);
    if (signal.aborted) onAbort();
    else signal.addEventListener('abort', onAbort, { once: true });
  });
}

async function asyncTile({ origins, destinations, rowOffset, columnOffset, matrix, apiKey, signal, fetchImpl }) {
  const url = `${BASE}/async?key=${encodeURIComponent(apiKey)}`;
  const body = { origins: points(origins), destinations: points(destinations),
    options: { traffic: 'live', departAt: 'now' } };
  const submission = await responseJson(await fetchImpl(url, { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal }), 'submission');
  if (typeof submission.jobId !== 'string' || !submission.jobId) throw new Error('TomTom Matrix returned no job ID');
  const statusUrl = `${BASE}/async/${encodeURIComponent(submission.jobId)}?key=${encodeURIComponent(apiKey)}`;
  let state = submission.state;
  while (state !== 'Completed' && state !== 'Failed') {
    await pause(2000, signal);
    const status = await responseJson(await fetchImpl(statusUrl, { signal }), 'status');
    state = status.state;
    if (state === 'Failed') throw new Error(`TomTom Matrix job failed: ${status.detailedError?.code ?? 'unknown'}`);
  }
  if (state === 'Failed') throw new Error('TomTom Matrix job failed');
  const resultUrl = `${BASE}/async/${encodeURIComponent(submission.jobId)}/result?key=${encodeURIComponent(apiKey)}`;
  const result = await responseJson(await fetchImpl(resultUrl, { signal }), 'download');
  copyCells(result, matrix, rowOffset, columnOffset, origins.length, destinations.length);
}

/**
 * Road-time matrix in seconds. Up to 100 cells use TomTom's synchronous API;
 * larger matrices use bounded 50×50 async tiles. Missing roads fail closed.
 * Matrix polling never retries the Python solver.
 */
export async function getTomTomDistanceMatrix(coordinates, externalSignal, fetchImpl = fetch) {
  const apiKey = process.env.TOMTOM_API_KEY;
  if (!apiKey) throw new Error('TOMTOM_API_KEY is missing');
  if (!Array.isArray(coordinates) || !coordinates.length || coordinates.length > 250 ||
    coordinates.some(point => ![point.lat, point.lng].every(Number.isFinite)))
    throw new Error('TomTom Matrix coordinates are invalid or exceed the bounded batch');
  const signal = externalSignal ? AbortSignal.any([externalSignal, AbortSignal.timeout(95000)]) : AbortSignal.timeout(95000);
  const size = coordinates.length;
  const matrix = rows(size);
  if (size * size <= 100) {
    const result = await responseJson(await fetchImpl(`${BASE}?key=${encodeURIComponent(apiKey)}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal,
      body: JSON.stringify({ origins: points(coordinates), destinations: points(coordinates),
        options: { traffic: 'live', departAt: 'now' } })
    }), 'synchronous request');
    copyCells(result, matrix, 0, 0, size, size);
  } else {
    const tiles = [];
    for (let row = 0; row < size; row += ASYNC_TILE_SIDE)
      for (let column = 0; column < size; column += ASYNC_TILE_SIDE)
        tiles.push({ row, column });
    let nextTile = 0;
    await Promise.all(Array.from({ length: Math.min(4, tiles.length) }, async () => {
      while (nextTile < tiles.length) {
        signal.throwIfAborted();
        const { row, column } = tiles[nextTile++];
        await asyncTile({ origins: coordinates.slice(row, row + ASYNC_TILE_SIDE),
          destinations: coordinates.slice(column, column + ASYNC_TILE_SIDE),
          rowOffset: row, columnOffset: column, matrix, apiKey, signal, fetchImpl });
      }
    }));
  }
  if (matrix.some(row => row.some(value => value === null)))
    throw new Error('TomTom Matrix omitted a route cell');
  return matrix;
}
