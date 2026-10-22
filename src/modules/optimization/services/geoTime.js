const EARTH_METRES = 6371000;

export function metresBetween(a, b) {
  if (!a || !b || ![a.lat, a.lng, b.lat, b.lng].every(Number.isFinite)) throw new Error('Valid coordinates required');
  const radians = Math.PI / 180;
  const lat = (b.lat - a.lat) * radians;
  const lng = (b.lng - a.lng) * radians;
  const h = Math.sin(lat / 2) ** 2 + Math.cos(a.lat * radians) * Math.cos(b.lat * radians) * Math.sin(lng / 2) ** 2;
  return EARTH_METRES * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

export function travelMinutes(a, b, planning = {}) {
  const speed = planning.speedKmh ?? 20;
  const circuity = planning.circuityFactor ?? 1.3;
  if (!Number.isFinite(speed) || speed <= 0 || !Number.isFinite(circuity) || circuity < 1) throw new Error('Invalid planning factors');
  return metresBetween(a, b) / 1000 / speed * 60 * circuity;
}

export function openInsertionMinutes(anchor, satellites, successor, matrix) {
  if (!Array.isArray(satellites) || !satellites.length) return 0;
  if (typeof matrix !== 'function') throw new Error('Route matrix lookup required');
  const direct = matrix(anchor, successor);
  let inserted = 0;
  let previous = anchor;
  for (const satellite of satellites) {
    inserted += matrix(previous, satellite);
    previous = satellite;
  }
  inserted += matrix(previous, successor);
  if (![direct, inserted].every(value => Number.isFinite(value) && value >= 0)) throw new Error('Route matrix has no usable path');
  return Math.max(0, inserted - direct);
}

// At launch there are at most five satellites, so exhaustive order search is bounded.
export function bestSatelliteOrder(anchor, satellites, successor, matrix) {
  if (satellites.length > 5) throw new Error('Satellite order search is bounded to five');
  let best = { satellites: [], detourMinutes: satellites.length ? Infinity : 0 };
  function visit(prefix, remaining) {
    if (!remaining.length) {
      const detourMinutes = openInsertionMinutes(anchor, prefix, successor, matrix);
      const key = prefix.map(item => item.id).join('|');
      const bestKey = best.satellites.map(item => item.id).join('|');
      if (detourMinutes < best.detourMinutes || (detourMinutes === best.detourMinutes && key < bestKey)) {
        best = { satellites: prefix, detourMinutes };
      }
      return;
    }
    for (const item of remaining) visit([...prefix, item], remaining.filter(other => other !== item));
  }
  visit([], satellites);
  return best;
}

export function provisionalAnchorSuccessors(groups, depot) {
  const successors = new Map();
  const crewIds = [...new Set(groups.map(group => group.planned_crew_id))].sort();
  for (const crewId of crewIds) {
    const remaining = groups.filter(group => group.planned_crew_id === crewId);
    let current = depot;
    const ordered = [];
    while (remaining.length) {
      remaining.sort((a, b) => metresBetween(current, a.centre) - metresBetween(current, b.centre)
        || a.group_key.localeCompare(b.group_key));
      const next = remaining.shift();
      ordered.push(next);
      current = next.centre;
    }
    ordered.forEach((group, index) => successors.set(group.group_key, ordered[index + 1]?.centre ?? depot));
  }
  return successors;
}
