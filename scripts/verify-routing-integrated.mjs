// T07 integrated check: real backend login, auth middleware and the real routing provider with non-sensitive public coordinates.
import assert from 'node:assert/strict';
import {readFileSync,mkdirSync,writeFileSync} from 'node:fs';
const api='http://127.0.0.1:4102',fixtures=JSON.parse(readFileSync('.private/parity-fixtures.json','utf8'));
assert.equal(fixtures.url,'http://127.0.0.1:54321');
const results=[];const check=(name,ok)=>{assert.ok(ok,name);results.push(name);console.log('PASS '+name);};
const login=async role=>{const u=fixtures.users.find(x=>x.role===role);const r=await fetch(api+'/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:u.email,password:fixtures.password})});
 assert.equal(r.status,200,'login '+role);const d=await r.json();return d.session?.access_token||d.access_token||d.token;};
// Pasig City Hall area to a nearby point; fixed public coordinates, no user data.
const from='121.0800,14.5700',to='121.0850,14.5750',url=(f=from,t=to)=>`${api}/api/routing/directions?from=${encodeURIComponent(f)}&to=${encodeURIComponent(t)}`;
const get=(token,u)=>fetch(u,{headers:token?{Authorization:`Bearer ${token}`}:{}});
const haversine=([lng1,lat1],[lng2,lat2])=>{const r=x=>x*Math.PI/180,a=Math.sin(r(lat2-lat1)/2)**2+Math.cos(r(lat1))*Math.cos(r(lat2))*Math.sin(r(lng2-lng1)/2)**2;return 12742000*Math.asin(Math.sqrt(a));};
const tokens={};for(const role of ['field_crew','officer','admin','citizen'])tokens[role]=await login(role);
const response=await get(tokens.field_crew,url());assert.equal(response.status,200,'crew directions');
const body=await response.json(),route=body.routes?.[0];
check('field crew receives a real provider route',body.code==='Ok'&&route.distance>0&&route.legs.flatMap(l=>l.steps).length>0);
check('directions are never publicly cached',/no-store|private/.test(response.headers.get('cache-control')||''));
const coords=route.geometry.coordinates,[dLng,dLat]=to.split(',').map(Number);
check('route starts and ends near the confirmed coordinates',haversine(coords[0],[121.08,14.57])<150&&haversine(coords.at(-1),[dLng,dLat])<150);
check('steps carry maneuver locations for the mobile parser',route.legs.flatMap(l=>l.steps).every(s=>Array.isArray(s.maneuver?.location)&&s.maneuver.location.length===2));
for(const role of ['officer','admin'])check(`${role} may request directions`,(await get(tokens[role],url())).status===200);
check('citizen is denied',(await get(tokens.citizen,url())).status===403);
check('signed-out request is denied',(await get(null,url())).status===401);
check('invalid token is denied',(await get('not-a-token',url())).status===401);
const phone=await get(tokens.field_crew,url('121.08000049999999,14.57000051234567','121.08500049999999,14.57500051234567'));
check('long phone GPS precision is accepted',phone.status===200);
for(const [name,f,t] of [['missing from',undefined,to],['swapped lat,lng order','14.57,121.08',to],['non-numeric','a,b',to],['outside service area','-122.4,37.8',to],['null island','0,0',to]])
 check('invalid input refused: '+name,(await get(tokens.field_crew,f===undefined?`${api}/api/routing/directions?to=${to}`:url(f,t))).status===400);
mkdirSync('.private/t07',{recursive:true});writeFileSync('.private/t07/results.json',JSON.stringify({results},null,1));
console.log(`ALL ${results.length} CHECKS PASSED`);
