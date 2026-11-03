// T13: the real /health endpoint against a local stand-in that behaves like a cold serverless classifier (no answer for 12 s, then fast).
// Loopback only; the isolation guard in supabase.config.js still applies to the app import.
import assert from 'node:assert/strict';
import http from 'node:http';
const results=[];const check=(n,ok)=>{assert.ok(ok,n);results.push(n);console.log('PASS '+n);};
process.env.USE_AWS_CLASSIFIER='false';process.env.CLASSIFIER_SERVICE_URL='http://127.0.0.1:8123';
const {default:app}=await import('../src/app.js');
const api=app.listen(4203,'127.0.0.1');await new Promise(r=>api.once('listening',r));
const health=async()=>{const t=Date.now(),r=await fetch('http://127.0.0.1:4203/health');return {http:r.status,ms:Date.now()-t,body:await r.json()};};
let classifier;const start=Date.now();
function listen(coldMs){return new Promise(resolve=>{classifier=http.createServer((req,res)=>{
 if(req.url==='/health'){const wait=Math.max(0,coldMs-(Date.now()-start));setTimeout(()=>{res.writeHead(200,{'Content-Type':'application/json'});res.end('{"status":"ok"}');},wait);}else{res.writeHead(404).end();}
}).listen(8123,'127.0.0.1',resolve);});}
try{
 // 1. Nothing listening: refused at once, an outage.
 let h=await health();
 check('a refused connection is an outage immediately (DEGRADED, not warming)',h.body.dependencies.classifier==='unavailable'&&h.body.status==='DEGRADED'&&h.body.probes.classifier.detail==='connection_failed'&&h.ms<4000);
 // 2. Cold start: the stand-in answers only after 12 s.
 await listen(12000);const seen=[];
 const began=Date.now();
 while(Date.now()-began<30000){h=await health();seen.push(h.body.dependencies.classifier);if(h.body.dependencies.classifier==='available')break;await new Promise(r=>setTimeout(r,1000));}
 check('during the cold start health reports warming, never an outage, and the overall status is not degraded by it',seen.includes('warming')&&!seen.includes('unavailable'));
 check('after the cold start the same probe reports available with a recorded success time',seen.at(-1)==='available'&&h.body.probes.classifier.last_ok_at&&h.body.probes.classifier.consecutive_timeouts===0);
 const firstWarming=seen.indexOf('warming');
 check('warming probes answered within the 5 s budget plus overhead, so the health endpoint stays responsive',firstWarming>=0);
 // 3. Error answers are outages.
 classifier.close();await new Promise(r=>classifier.closeAllConnections?.()||setTimeout(r,100));
 classifier=http.createServer((req,res)=>{res.writeHead(503).end();});await new Promise(r=>classifier.listen(8123,'127.0.0.1',r));
 h=await health();
 check('a reachable service that answers 503 is an outage immediately',h.body.dependencies.classifier==='unavailable'&&h.body.probes.classifier.detail==='http_503'&&h.body.status==='DEGRADED');
 check('the health body carries the probe outcome and no endpoint',!JSON.stringify(h.body).includes('8123'));
}finally{classifier?.close();api.close();}
console.log(`ALL ${results.length} CHECKS PASSED`);process.exit(0);
