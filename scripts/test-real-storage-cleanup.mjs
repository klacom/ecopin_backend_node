import fs from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID,createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import assert from 'node:assert/strict';
import {createClient} from '@supabase/supabase-js';

const root='C:/dev/App-Builders-Hackathon/.ecopin-optimization/.private/local-supabase-recovery';
const local=JSON.parse(await fs.readFile(join(root,'status.private.json'),'utf8'));
assert.equal(new URL(local.API_URL).hostname,'127.0.0.1','Local Supabase only');
const child=process.argv[2]==='--drain-only';
const directory=child?resolve(process.argv[3]):await fs.mkdtemp(join(root,'cleanup-byte-verification-'));
assert.ok(directory.startsWith(resolve(root)+'\\')||directory.startsWith(resolve(root)+'/'),'Private recovery directory only');
process.env.NEXT_PUBLIC_SUPABASE_URL=local.API_URL;
process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY=local.SERVICE_ROLE_KEY;
process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY=local.ANON_KEY;
process.env.STORAGE_CLEANUP_DIRECTORY=directory;
const {removeOrQueue,drainStorageCleanup}=await import('../src/services/storage-cleanup.service.js');
const {supabaseAdmin:handler}=await import('../src/config/supabase.config.js');
if(child){await drainStorageCleanup();}else{
const admin=createClient(local.API_URL,local.SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const bucket='Cleanup Task Photos', taskId=randomUUID();
const paths=[`${taskId}/before/${randomUUID()}.png`,`${taskId}/before/${randomUUID()}.png`];
const bytes=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG0sAAAAASUVORK5CYII=','base64');
const checks=[];
const check=(name,passed)=>{assert.ok(passed,name);checks.push({test:name,status:'PASS'});console.log('PASS '+name)};
const ensure=result=>{if(result.error) throw new Error(`Local fixture operation failed: ${result.error.code??result.error.statusCode??'UNKNOWN'}`);return result.data};
const reference=path=>admin.storage.from(bucket).getPublicUrl(path).data.publicUrl;
let created=false;
try{
 ensure(await admin.from('cleanup_tasks').insert({id:taskId,title:'Private cleanup byte fixture',status:'pending',route_status:'ready',assigned_crew_ids:[]}));created=true;
 for(const path of paths)ensure(await admin.storage.from(bucket).upload(path,bytes,{contentType:'image/png',upsert:false}));
 ensure(await admin.from('cleanup_tasks').update({before_photo_url:reference(paths[0])}).eq('id',taskId));
 await removeOrQueue(bucket,paths[0]);
 const retained=ensure(await admin.storage.from(bucket).download(paths[0]));
 check('Referenced image remains byte-for-byte intact',Buffer.from(await retained.arrayBuffer()).equals(bytes));
 ensure(await admin.from('cleanup_tasks').update({before_photo_url:reference(paths[1])}).eq('id',taskId));
 await removeOrQueue(bucket,paths[0]);
 check('Detached replaced image is removed',!!(await admin.storage.from(bucket).download(paths[0])).error);
 const replacement=ensure(await admin.storage.from(bucket).download(paths[1]));
 check('Current replacement image remains intact',Buffer.from(await replacement.arrayBuffer()).equals(bytes));
 ensure(await admin.from('cleanup_tasks').update({before_photo_url:null}).eq('id',taskId));
 const original=handler.storage.from;
 handler.storage.from=function(name){const storage=original.call(this,name);storage.remove=async()=>({error:{code:'TEST_STORAGE_UNAVAILABLE'}});return storage};
 try{await removeOrQueue(bucket,paths[1]);}finally{handler.storage.from=original;}
 const jobs=(await fs.readdir(directory)).filter(name=>name.endsWith('.json'));
 check('Failed byte deletion is persisted',jobs.length===1);
 const file=join(directory,jobs[0]), job=JSON.parse(await fs.readFile(file,'utf8'));
 check('Failure records one retry and sanitized error',job.attempts===1&&job.errorCode==='TEST_STORAGE_UNAVAILABLE');
 check('Image remains available after failed removal',!(await admin.storage.from(bucket).download(paths[1])).error);
 // Advance only this isolated job's eligibility; do not sleep for the backoff interval.
 job.availableAt=0;await fs.writeFile(file,JSON.stringify(job));
 await promisify(execFile)(process.execPath,[new URL(import.meta.url).pathname.replace(/^\/(\w:)/,'$1'),'--drain-only',directory],{timeout:30000});
 check('New process resumes the persisted job and removes bytes',!!(await admin.storage.from(bucket).download(paths[1])).error);
 check('Successful recovery clears the durable job',(await fs.readdir(directory)).length===0);
}finally{
 if(created){ensure(await admin.from('cleanup_tasks').update({before_photo_url:null,after_photo_url:null}).eq('id',taskId));ensure(await admin.storage.from(bucket).remove(paths));ensure(await admin.from('cleanup_tasks').delete().eq('id',taskId));}
 // Keep the empty private directory; failed journals are deliberately retained for diagnosis.
}
await fs.writeFile('C:/dev/App-Builders-Hackathon/.ecopin-optimization/REAL_STORAGE_CLEANUP_VERIFICATION.json',JSON.stringify({verified_at:new Date().toISOString(),environment:'Private local Supabase; production cleanup service and new worker process',assertions_passed:checks.length,fixture_sha256:createHash('sha256').update(bytes).digest('hex'),checks},null,2));

}
