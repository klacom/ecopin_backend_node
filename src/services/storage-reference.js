export const PRIVATE_MEDIA_BUCKETS=['Report Evidence','Cleanup Task Photos','Report Cleanup','Cleanup Originals'];
export function validStoragePath(bucket,path){
  if(!PRIVATE_MEDIA_BUCKETS.includes(bucket)||typeof path!=='string'||path.length>1024) return false;
  const parts=path.split('/');
  if(parts.some(part=>!part||part==='.'||part==='..'||!/^[a-zA-Z0-9._-]{1,128}$/.test(part))) return false;
  if(bucket==='Report Evidence') return parts.length>=2&&parts.length<=6;
  return parts.length===3&&['before','after'].includes(parts[1]);
}
export function storageReference(bucket,path){
  if(!validStoragePath(bucket,path)) throw new Error('Invalid private Storage reference');
  return `storage://${encodeURIComponent(bucket)}/${path}`;
}
export function parseStorageReference(value,origin){
  if(typeof value!=='string') return null;
  try{
    const url=new URL(value);let bucket,path;
    if(url.protocol==='storage:'){
      if(url.search||url.hash||url.username||url.password) return null;
      bucket=decodeURIComponent(url.host);path=decodeURIComponent(url.pathname.slice(1));
    }else{
      if(!origin||url.origin!==new URL(origin).origin||url.username||url.password) return null;
      const match=url.pathname.match(/^\/storage\/v1\/object\/(?:public|sign|authenticated)\/([^/]+)\/(.+)$/);
      if(!match) return null;bucket=decodeURIComponent(match[1]);path=decodeURIComponent(match[2]);
    }
    return validStoragePath(bucket,path)?{bucket,path}:null;
  }catch{return null;}
}
