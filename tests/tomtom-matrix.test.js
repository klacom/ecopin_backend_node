import { jest } from '@jest/globals';
import { getTomTomDistanceMatrix } from '../src/modules/optimization/providers/tomtom.provider.js';

const point = { lat: 14, lng: 121 };
const cellData = size => Array.from({ length: size }, (_, originIndex) =>
  Array.from({ length: size }, (_, destinationIndex) => ({ originIndex, destinationIndex,
    routeSummary: { travelTimeInSeconds: originIndex === destinationIndex ? 0 : 60 } }))).flat();
const ok = data => ({ ok: true, json: async () => data });

test('small TomTom matrix uses a valid live-traffic departure and rejects missing cells', async () => {
  const previous = process.env.TOMTOM_API_KEY;
  process.env.TOMTOM_API_KEY = 'test';
  try {
    const fetchImpl = jest.fn(async () => ok({ data: cellData(2) }));
    const matrix = await getTomTomDistanceMatrix([point, point], undefined, fetchImpl);
    expect(matrix).toEqual([[0, 60], [60, 0]]);
    expect(JSON.parse(fetchImpl.mock.calls[0][1].body).options).toEqual({ traffic: 'live', departAt: 'now' });
    await expect(getTomTomDistanceMatrix([point, point], undefined,
      async () => ok({ data: cellData(2).slice(0, 3) }))).rejects.toThrow('omitted');
  } finally { if (previous === undefined) delete process.env.TOMTOM_API_KEY; else process.env.TOMTOM_API_KEY = previous; }
});

test('larger matrix is submitted asynchronously with a bounded tile, then downloaded', async () => {
  const previous = process.env.TOMTOM_API_KEY;
  process.env.TOMTOM_API_KEY = 'test';
  try {
    const urls = [];
    const fetchImpl = async (url, options) => {
      urls.push(url);
      if (options?.method === 'POST') return ok({ jobId: 'matrix-1', state: 'Completed' });
      return ok({ data: cellData(11) });
    };
    const matrix = await getTomTomDistanceMatrix(Array(11).fill(point), undefined, fetchImpl);
    expect(matrix).toHaveLength(11);
    expect(urls).toHaveLength(2);
    expect(urls[0]).toContain('/async?');
    expect(urls[1]).toContain('/async/matrix-1/result?');
  } finally { if (previous === undefined) delete process.env.TOMTOM_API_KEY; else process.env.TOMTOM_API_KEY = previous; }
});

test('a matrix above one async tile is assembled in the original point order', async () => {
  const previous = process.env.TOMTOM_API_KEY;
  process.env.TOMTOM_API_KEY = 'test';
  try {
    const jobs = new Map();
    let submitted = 0;
    const fetchImpl = async (url, options) => {
      if (options?.method === 'POST') {
        const payload = JSON.parse(options.body);
        const id = `tile-${++submitted}`;
        jobs.set(id, { rows: payload.origins.length, columns: payload.destinations.length,
          firstRow: payload.origins[0].point.latitude - 14,
          firstColumn: payload.destinations[0].point.latitude - 14 });
        return ok({ jobId: id, state: 'Completed' });
      }
      const id = url.match(/async\/(tile-\d+)\/result/)[1];
      const tile = jobs.get(id);
      return ok({ data: Array.from({ length: tile.rows }, (_, originIndex) =>
        Array.from({ length: tile.columns }, (_, destinationIndex) => ({ originIndex, destinationIndex,
          routeSummary: { travelTimeInSeconds: (tile.firstRow + originIndex) * 100 +
            tile.firstColumn + destinationIndex } })).flat()).flat() });
    };
    const coordinates = Array.from({ length: 51 }, (_, index) => ({ lat: 14 + index, lng: 121 }));
    const matrix = await getTomTomDistanceMatrix(coordinates, undefined, fetchImpl);
    expect(submitted).toBe(4);
    expect(matrix[0][50]).toBe(50);
    expect(matrix[50][0]).toBe(5000);
    expect(matrix[50][50]).toBe(5050);
  } finally { if (previous === undefined) delete process.env.TOMTOM_API_KEY; else process.env.TOMTOM_API_KEY = previous; }
});
