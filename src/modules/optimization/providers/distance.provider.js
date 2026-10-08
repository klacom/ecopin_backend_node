function haversine(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180;
  const a = Math.sin((lat2-lat1)*rad/2)**2 + Math.cos(lat1*rad)*Math.cos(lat2*rad)*Math.sin((lon2-lon1)*rad/2)**2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
}
export async function getDistanceAndDuration(lat1, lon1, lat2, lon2, provider = 'haversine', signal, travelMode = 'DRIVING') {
  if (![lat1, lon1, lat2, lon2].every(Number.isFinite) || Math.abs(lat1)>90 || Math.abs(lat2)>90 || Math.abs(lon1)>180 || Math.abs(lon2)>180) throw new Error('Invalid route coordinates');
  signal?.throwIfAborted();
  if (provider === 'haversine') {
    const distance_meters = haversine(lat1, lon1, lat2, lon2);
    return { distance_meters, duration_min: distance_meters / ({ DRIVING: 500, BICYCLE: 250, WALKING: 80 }[travelMode] ?? 500), approximate: true };
  }
  if (provider !== 'tomtom') throw new Error('Unsupported distance provider');
  if (!process.env.TOMTOM_API_KEY) throw new Error('TomTom routing is not configured');
  const response = await fetch(`https://api.tomtom.com/routing/1/calculateRoute/${lat1},${lon1}:${lat2},${lon2}/json?key=${encodeURIComponent(process.env.TOMTOM_API_KEY)}&traffic=true&travelMode=${{ DRIVING: 'car', BICYCLE: 'bicycle', WALKING: 'pedestrian' }[travelMode] ?? 'car'}`, {
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(8000)]) : AbortSignal.timeout(8000)
  });
  if (!response.ok) throw new Error(`Routing provider returned ${response.status}`);
  const route = (await response.json()).routes?.[0];
  const distance_meters = route?.summary?.lengthInMeters;
  const duration_min = route?.summary?.travelTimeInSeconds / 60;
  if (![distance_meters, duration_min].every(value => Number.isFinite(value) && value>=0)) throw new Error('Routing provider returned no usable route');
  return { distance_meters, duration_min, polyline: route.legs?.flatMap(leg => leg.points ?? []) ?? [], approximate: false };
}
