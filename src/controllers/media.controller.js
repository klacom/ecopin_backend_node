import {createClient} from '@supabase/supabase-js';
import * as config from '../config/index.js';
import {validStoragePath} from '../services/storage-reference.js';

export async function getStorageMedia(req,res,next){
  const {bucket,path}=req.query;
  if(!validStoragePath(bucket,path)) return res.status(400).json({message:'Invalid media reference'});
  const authorization=req.headers.authorization;
  if(!authorization?.startsWith('Bearer ')) return res.status(401).json({message:'Authentication required'});
  try{
    // Use the caller's JWT and the publishable/anon key. The service key must
    // never bypass Storage policies for delivery, even for a known object path.
    const client=createClient(config.NEXT_PUBLIC_SUPABASE_URL,config.SUPABASE_ANON_KEY,{
      auth:{persistSession:false,autoRefreshToken:false},
      global:{headers:{Authorization:authorization}}
    });
    const {data,error}=await client.storage.from(bucket).download(path);
    if(error||!data) return res.status(404).json({message:'Media unavailable'});
    res.set('Cache-Control','private, no-store');
    res.set('Vary','Authorization');
    res.set('X-Content-Type-Options','nosniff');
    res.set('Content-Security-Policy',"sandbox; default-src 'none'");
    res.set('Content-Type',data.type||'application/octet-stream');
    return res.send(Buffer.from(await data.arrayBuffer()));
  }catch(error){next(error);}
}
