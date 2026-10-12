import {mkdir, readFile, writeFile, rename, readdir, unlink, stat, rmdir} from 'node:fs/promises';
import {join} from 'node:path';
import {createHash, randomUUID} from 'node:crypto';

// Persist this directory across backend restarts. Each job is published atomically.
export function createStorageCleanupQueue({directory,remove,isReferenced,clock=Date.now}) {
  const leaseMs=5*60*1000;
  const save=async(file,job)=>{
    const temporary=`${file}.${randomUUID()}.tmp`;
    await writeFile(temporary,JSON.stringify(job),{mode:0o600,flag:'wx'});
    await rename(temporary,file);
  };
  const enqueue=async(bucket,path)=>{
    if(bucket!=='Cleanup Task Photos'||!/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/(before|after)\/[a-zA-Z0-9._-]{1,128}$/i.test(path)||['.','..'].includes(path.split('/')[2])) throw new Error('Invalid cleanup object');
    await mkdir(directory,{recursive:true,mode:0o700});
    const id=createHash('sha256').update(`${bucket}\0${path}`).digest('hex');
    const file=join(directory,`${id}.json`);
    // Exclusive creation deduplicates repeated enqueue calls without resetting attempts.
    const staging=join(directory,`${id}.${randomUUID()}.tmp`);
    await writeFile(staging,JSON.stringify({bucket,path,status:'pending',attempts:0,availableAt:clock()}),{mode:0o600,flag:'wx'});
    try {
      const {link}=await import('node:fs/promises');
      await link(staging,file);
    } catch(error) {if(error.code!=='EEXIST') throw error;}
    finally {await unlink(staging);}
  };
  const drain=async({limit=20}={})=>{
    await mkdir(directory,{recursive:true,mode:0o700});
    const files=(await readdir(directory)).filter(name=>/^[0-9a-f]{64}\.json$/.test(name));
    let processed=0;
    for(const name of files){
      if(processed>=limit) break;
      const file=join(directory,name), lock=`${file}.lock`;
      try {await mkdir(lock);} catch(error){
        if(error.code!=='EEXIST') throw error;
        try {if(clock()-(await stat(lock)).mtimeMs>leaseMs) await rmdir(lock);} catch(staleError){if(staleError.code!=='ENOENT') throw staleError;}
        continue;
      }
      try {
        let job;
        try {job=JSON.parse(await readFile(file,'utf8'));} catch(error){if(error.code==='ENOENT') continue;throw error;}
        if(job.status==='failed'||job.availableAt>clock()) continue;
        processed++;
        try {
          if(await isReferenced(job.bucket,job.path)){await unlink(file);continue;}
          const result=await remove(job.bucket,job.path);
          if(result?.error) throw result.error;
          await unlink(file);
        } catch(error){
          job.attempts++;
          job.status=job.attempts>=5?'failed':'pending';
          job.availableAt=clock()+Math.min(3600000,60000*2**(job.attempts-1));
          job.errorCode=/^[a-zA-Z0-9_-]{1,40}$/.test(error?.code??'')?error.code:'CLEANUP_FAILED';
          await save(file,job);
          if(job.status==='failed') console.error('[Storage cleanup] retries exhausted',name);
        }
      } finally {await rmdir(lock).catch(error=>{if(error.code!=='ENOENT') throw error;});}
    }
  };
  return {enqueue,drain};
}
