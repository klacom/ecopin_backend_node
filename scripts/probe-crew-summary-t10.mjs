import fs from 'node:fs';
const root='C:/dev/ecopin/.tmp/parity-recovery-backend',f=JSON.parse(fs.readFileSync(root+'/.private/parity-fixtures.json','utf8')),api='http://127.0.0.1:4102';
const o=f.users.find(u=>u.role==='officer');
const d=await (await fetch(api+'/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:o.email,password:f.password})})).json();
const t=d.session?.access_token||d.access_token||d.token;
for(const [a,b] of [process.argv.slice(2,4)]){const r=await fetch(`${api}/api/sweeper/operations-summary?from=${a}&through=${b}`,{headers:{Authorization:'Bearer '+t}});const j=await r.json();
 console.log(r.status,Object.fromEntries(['tasks','assignments','waypoints','verified','obstacles'].map(k=>[k,j[k]?.length])),j.error||'');}
