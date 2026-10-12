import {fileURLToPath} from 'node:url';
import {supabaseAdmin} from '../config/supabase.config.js';
import {createStorageCleanupQueue} from './storage-cleanup.queue.js';

const directory=process.env.STORAGE_CLEANUP_DIRECTORY || fileURLToPath(new URL('../../.private/storage-cleanup/',import.meta.url));
const queue=createStorageCleanupQueue({
  directory,
  remove:(bucket,path)=>supabaseAdmin.storage.from(bucket).remove([path]),
  isReferenced:async(bucket,path)=>{
    const {data,error}=await supabaseAdmin.from('cleanup_tasks').select('before_photo_url,after_photo_url').eq('id',path.split('/')[0]).maybeSingle();
    if(error) throw error;
    return [data?.before_photo_url,data?.after_photo_url].some(value=>typeof value==='string'&&value.split('?')[0].endsWith(`/${path}`));
  }
});
// Write intent before attempting external deletion; a crash leaves a recoverable job.
export async function removeOrQueue(bucket,path){await queue.enqueue(bucket,path);await drainStorageCleanup();}
let running=null, timer=null;
export function drainStorageCleanup(){
  if(!running) running=queue.drain().finally(()=>{running=null});
  return running;
}
export function startStorageCleanup(){
  if(timer) return;
  const tick=()=>drainStorageCleanup().catch(()=>console.error('[Storage cleanup] worker failed; persisted jobs retained'));
  timer=setInterval(tick,60000);timer.unref();tick();
}
export function stopStorageCleanup(){if(timer) clearInterval(timer);timer=null;}
