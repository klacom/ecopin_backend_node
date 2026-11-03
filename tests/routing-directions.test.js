import {jest} from '@jest/globals';
const {getDrivingDirections,parsePoint}=await import('../src/controllers/routing.controller.js');
const {ROLE_GROUPS}=await import('../src/constants/roles.js');
const response=()=>({status:jest.fn().mockReturnThis(),json:jest.fn(),set:jest.fn().mockReturnThis()});
const from='121.0800,14.5700',to='121.0850,14.5750';
const route={code:'Ok',routes:[{distance:700,duration:90,geometry:{coordinates:[[121.08,14.57],[121.085,14.575]]},legs:[{steps:[{maneuver:{location:[121.08,14.57]}}]}]}]};
const upstream=(status,body)=>({ok:status>=200&&status<300,status,json:async()=>{if(body instanceof Error)throw body;return body;}});
beforeEach(()=>{global.fetch=jest.fn();});
afterAll(()=>{delete global.fetch;});

test('only desk and field roles may request directions',()=>{
 expect(ROLE_GROUPS.FIELD_OPS.sort()).toEqual(['admin','field_crew','officer']);
});
test.each([[undefined,to],[from,undefined],['x',to],['121.08,14.57,3',to],['121.08;14.57',to],['NaN,NaN',to],['121.08,91',to],
 ['0,0',to],['-122.4,37.8',to],['121.0800,14.20',to],['121.5,14.57',to],[['121.08,14.57','121.09,14.58'],to]])('invalid or out-of-area input is refused before the provider: %j -> %j',async(f,t)=>{
 const res=response();await getDrivingDirections({query:{from:f,to:t}},res);
 expect(res.status).toHaveBeenCalledWith(400);expect(global.fetch).not.toHaveBeenCalled();
});
test('long phone GPS coordinates are rounded and sent as lng,lat to the provider',async()=>{
 global.fetch.mockResolvedValueOnce(upstream(200,route));
 const res=response();await getDrivingDirections({query:{from:'121.08000049999999,14.57000051234567',to}},res);
 const url=global.fetch.mock.calls[0][0];expect(url).toContain('/route/v1/driving/121.080001,14.570001;121.085,14.575?');
 expect(res.status).toHaveBeenCalledWith(200);expect(res.json).toHaveBeenCalledWith(route);expect(res.set).toHaveBeenCalledWith('Cache-Control','private, max-age=30');
});
test('the confirmed destination is the route end point',()=>{
 expect(parsePoint(to)).toEqual({lat:14.575,lng:121.085});
});
test.each([[502,{message:'x'}],[500,{}]])('provider HTTP %i is a 502 with no directions',async(status,body)=>{
 global.fetch.mockResolvedValueOnce(upstream(status,body));
 const res=response();await getDrivingDirections({query:{from,to}},res);expect(res.status).toHaveBeenCalledWith(502);expect(res.json).toHaveBeenCalledWith({message:'Directions are temporarily unavailable.'});
});
test('a provider timeout is a 504',async()=>{
 global.fetch.mockRejectedValueOnce(Object.assign(new Error('timeout'),{name:'TimeoutError'}));
 const res=response();await getDrivingDirections({query:{from,to}},res);expect(res.status).toHaveBeenCalledWith(504);
});
test('no road route is a 404, never a misleading route',async()=>{
 for(const [status,body] of [[400,{code:'NoRoute',message:'Impossible route'}],[200,{code:'NoRoute',routes:[]}],[200,{code:'Ok',routes:[]}]]){
  global.fetch.mockResolvedValueOnce(upstream(status,body));
  const res=response();await getDrivingDirections({query:{from,to}},res);
  expect(res.status).toHaveBeenCalledWith(404);expect(res.json).not.toHaveBeenCalledWith(expect.objectContaining({routes:expect.anything()}));expect(res.set).not.toHaveBeenCalled();
 }
});
test.each([[new SyntaxError('bad json')],[{}],[{code:'InvalidQuery'}],[{code:'Ok'}]])('an unreadable or unrecognised provider body is a 502: %j',async body=>{
 global.fetch.mockResolvedValueOnce(upstream(200,body));
 const res=response();await getDrivingDirections({query:{from,to}},res);expect(res.status).toHaveBeenCalledWith(502);expect(res.set).not.toHaveBeenCalled();
});
