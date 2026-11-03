import assert from 'node:assert/strict';
import https from 'node:https';
import {readFileSync} from 'node:fs';
import dotenv from 'dotenv';
import {createClient} from 'redis';

dotenv.config({quiet:true});
assert.equal(process.env.SUPABASE_URL,'http://127.0.0.1:54321','Only the isolated database is permitted.');
const config=JSON.parse(readFileSync('.private/t04/session.json','utf8'));
assert.ok(typeof config.token==='string'&&/^[A-Za-z0-9_-]{43,}$/.test(config.token),'Generate a fresh local session-store token.');
const redis=createClient({url:'redis://127.0.0.1:63791'});
redis.on('error',()=>console.error('Isolated session Redis unavailable'));
await redis.connect();
const sessionServer=https.createServer({key:readFileSync('.private/t04/localhost.key'),cert:readFileSync('.private/t04/localhost.crt')},async(req,res)=>{
  if(req.method!=='POST'||req.headers.authorization!==`Bearer ${config.token}`){res.writeHead(403).end();return;}
  try{
    let body='';for await(const chunk of req){body+=chunk;if(Buffer.byteLength(body)>131072)throw new Error('Too large');}
    const command=JSON.parse(body);
    assert.ok(Array.isArray(command)&&['GET','SET','DEL','EVAL'].includes(String(command[0]).toUpperCase()));
    const result=await redis.sendCommand(command.map(String));
    res.writeHead(200,{'Content-Type':'application/json'}).end(JSON.stringify({result}));
  }catch{res.writeHead(503,{'Content-Type':'application/json'}).end(JSON.stringify({error:'Local session store unavailable'}));}
});
await new Promise(resolve=>sessionServer.listen(9443,'127.0.0.1',resolve));
// Import the real route registrations without index.js, which starts background writers.
const {default:app}=await import('../src/app.js');
const api=app.listen(4102,'127.0.0.1',()=>console.log('Isolated API 4102 and HTTPS Redis bridge 9443 ready; background workers are not started.'));
async function stop(){api.close();sessionServer.close();await redis.quit();}
process.once('SIGINT',()=>void stop());process.once('SIGTERM',()=>void stop());
