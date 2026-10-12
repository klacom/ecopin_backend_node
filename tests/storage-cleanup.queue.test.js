import {jest} from '@jest/globals';
import {mkdtemp, readdir, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createStorageCleanupQueue} from '../src/services/storage-cleanup.queue.js';

const path='11111111-1111-4111-8111-111111111111/before/photo.jpg';
let directory, now, remove, isReferenced;
const queue=()=>createStorageCleanupQueue({directory,remove,isReferenced,clock:()=>now});
beforeEach(async()=>{directory=await mkdtemp(join(tmpdir(),'ecopin-cleanup-'));now=Date.now();remove=jest.fn().mockResolvedValue({error:null});isReferenced=jest.fn().mockResolvedValue(false)});
afterEach(async()=>{await rm(directory,{recursive:true,force:true})});
test('pending cleanup survives a new queue instance',async()=>{
 await queue().enqueue('Cleanup Task Photos',path);
 expect(remove).not.toHaveBeenCalled();
 await queue().drain();
 expect(remove).toHaveBeenCalledWith('Cleanup Task Photos',path);
 expect(await readdir(directory)).toEqual([]);
});
test('failure persists bounded retries and a visible terminal job',async()=>{
 remove.mockResolvedValue({error:{code:'503',message:'private signed URL must not be recorded'}});
 await queue().enqueue('Cleanup Task Photos',path);
 for(let i=0;i<5;i++){await queue().drain();now+=24*60*60*1000}
 await queue().drain();
 expect(remove).toHaveBeenCalledTimes(5);
 const files=await readdir(directory);expect(files).toHaveLength(1);
 const job=JSON.parse(await readFile(join(directory,files[0]),'utf8'));
 expect(job.status).toBe('failed');expect(job.attempts).toBe(5);
 expect(JSON.stringify(job)).not.toContain('private signed URL');
});
test('an object still referenced is retained',async()=>{
 isReferenced.mockResolvedValue(true);await queue().enqueue('Cleanup Task Photos',path);await queue().drain();expect(remove).not.toHaveBeenCalled();
});
test('independent workers do not process the same job concurrently',async()=>{
 let release;remove.mockImplementation(()=>new Promise(resolve=>{release=resolve}));
 await queue().enqueue('Cleanup Task Photos',path);const first=queue().drain();
 while(!release) await new Promise(resolve=>setTimeout(resolve,5));
 await queue().drain();expect(remove).toHaveBeenCalledTimes(1);
 release({error:null});await first;
});
test('invalid paths cannot enter the queue',async()=>{
 await expect(queue().enqueue('Cleanup Task Photos','../../other')).rejects.toThrow();
 expect(await readdir(directory)).toEqual([]);
});

test('failed jobs do not starve subsequent pending jobs',async()=>{
 remove.mockResolvedValue({error:{code:'503'}});
 await queue().enqueue('Cleanup Task Photos',path);
 for(let i=0;i<5;i++){await queue().drain({limit:1});now+=86400000}
 const hash=p=>createHash('sha256').update(`Cleanup Task Photos\0${p}`).digest('hex');
 let nextPath;
 for(let i=0;i<100;i++){const candidate=path.replace('photo.jpg',`next-${i}.jpg`);if(hash(candidate)>hash(path)){nextPath=candidate;break}}
 expect(nextPath).toBeDefined();await queue().enqueue('Cleanup Task Photos',nextPath);
 remove.mockResolvedValue({error:null});await queue().drain({limit:1});
 expect(remove).toHaveBeenCalledWith('Cleanup Task Photos',nextPath);
});
test('a job written by a terminated process is recovered by another process',async()=>{
 const moduleUrl=new URL('../src/services/storage-cleanup.queue.js',import.meta.url).href;
 const script=`import {createStorageCleanupQueue} from ${JSON.stringify(moduleUrl)}; await createStorageCleanupQueue({directory:${JSON.stringify(directory)}}).enqueue('Cleanup Task Photos',${JSON.stringify(path)});`;
 await promisify(execFile)(process.execPath,['--input-type=module','-e',script]);
 now=Date.now();
 await queue().drain();expect(remove).toHaveBeenCalledWith('Cleanup Task Photos',path);
});