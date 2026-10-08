import { jest } from '@jest/globals';
import { generateRouteForCrew } from '../src/modules/optimization/services/routeGenerator.service.js';
import { getDistanceAndDuration } from '../src/modules/optimization/providers/distance.provider.js';

test('route includes the return trip and applies the fleet speed factor',async()=>{
  const distance=jest.fn().mockResolvedValue({distance_meters:200,duration_min:4,approximate:false});
  const route=await generateRouteForCrew('crew',['task'],{latitude:14,longitude:121},'tomtom',{
    locations:new Map([['task',{lat:14.1,lng:121.1}]]),speedFactor:2,distance
  });
  expect(route.waypoints.map(w=>w.waypoint_type)).toEqual(['depot_start','task','depot_end']);
  expect(route.totalTime).toBe(4);expect(route.totalDistance).toBe(400);expect(route.approximate).toBe(false);
  expect(distance).toHaveBeenLastCalledWith(14.1,121.1,14,121,'tomtom',undefined,'DRIVING');
});
test('missing coordinates fail rather than routing to a fabricated location',async()=>{
  await expect(generateRouteForCrew('crew',['task'],{latitude:14,longitude:121},'none',{locations:new Map()})).rejects.toThrow('location unavailable');
});
test('provider failure propagates instead of silently changing the travel model',async()=>{
  await expect(generateRouteForCrew('crew',['task'],{latitude:14,longitude:121},'tomtom',{
    locations:new Map([['task',{lat:14.1,lng:121.1}]]),distance:async()=>{throw new Error('timeout');}
  })).rejects.toThrow('timeout');
});
test('approximate pilot routes are explicitly labeled',async()=>{
  const route=await generateRouteForCrew('crew',['task'],{latitude:14,longitude:121},'none',{locations:new Map([['task',{lat:14.1,lng:121.1}]])});
  expect(route.approximate).toBe(true);expect(route.totalTime).toBeGreaterThan(0);
});
test('invalid coordinates and cancelled runs fail closed',async()=>{
  await expect(getDistanceAndDuration(999,121,14,121)).rejects.toThrow('coordinates');
  await expect(getDistanceAndDuration(14,121,14,121,'haversine',AbortSignal.abort())).rejects.toThrow();
});


test('walking routes use walking travel duration rather than driving duration', async () => {
  const { getDistanceAndDuration } = await import('../src/modules/optimization/providers/distance.provider.js');
  const drive = await getDistanceAndDuration(14,121,14.01,121,'haversine',undefined,'DRIVING');
  const walk = await getDistanceAndDuration(14,121,14.01,121,'haversine',undefined,'WALKING');
  expect(walk.duration_min).toBeGreaterThan(drive.duration_min * 6);
  expect(walk.distance_meters).toBe(drive.distance_meters);
});
