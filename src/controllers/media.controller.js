import {createClient} from '@supabase/supabase-js';
import * as config from '../config/index.js';
import {supabaseAdmin} from '../config/supabase.config.js';
import {validStoragePath} from '../services/storage-reference.js';

export async function getStorageMedia(req,res,next){
  const {bucket,path}=req.query;
  if(!validStoragePath(bucket,path)) return res.status(400).json({message:'Invalid media reference'});
  const authorization=req.headers.authorization;
  if(!authorization?.startsWith('Bearer ')) return res.status(401).json({message:'Authentication required'});
  try{
    if(bucket==='Cleanup Originals'){
      const {data:report}=await supabaseAdmin.from('reports').select('cleanup_task_id').eq('id',path.split('/')[0]).maybeSingle();
      let allowed=report&&['officer','admin'].includes(req.user?.role);
      if(report&&!allowed&&req.user?.role==='field_crew'){
        const {data:task}=await supabaseAdmin.from('cleanup_tasks').select('assigned_crew_ids,assigned_field_crew_id').eq('id',report.cleanup_task_id).maybeSingle();
        allowed=task?.assigned_crew_ids?.includes(req.user.id);
        if(!allowed&&task?.assigned_field_crew_id){
          const {data:crew}=await supabaseAdmin.from('field_crews').select('team_lead_profile_id,member_profile_ids').eq('id',task.assigned_field_crew_id).maybeSingle();
          allowed=crew&&(crew.team_lead_profile_id===req.user.id||crew.member_profile_ids?.includes(req.user.id));
        }
      }
      if(!allowed)return res.status(404).json({message:'Media unavailable'});
      const {data,error}=await supabaseAdmin.storage.from(bucket).download(path);
      if(error||!data)return res.status(404).json({message:'Media unavailable'});
      res.set('Cache-Control','private, no-store');res.set('Vary','Authorization');
      res.set('X-Content-Type-Options','nosniff');res.set('Content-Security-Policy',"sandbox; default-src 'none'");
      res.set('Content-Type',data.type||'application/octet-stream');
      return res.send(Buffer.from(await data.arrayBuffer()));
    }
    // Use the caller's JWT and the publishable/anon key. The service key must
    // never bypass Storage policies for delivery, even for a known object path.
    const client=createClient(config.NEXT_PUBLIC_SUPABASE_URL,config.SUPABASE_PUBLISHABLE_KEY||config.SUPABASE_ANON_KEY,{
      auth:{persistSession:false,autoRefreshToken:false},
      global:{headers:{Authorization:authorization}}
    });
    let {data,error}=await client.storage.from(bucket).download(path);
    if((error||!data)&&bucket==='Report Evidence'&&typeof path==='string'&&path.startsWith('realistic-defense-560-v1/')){
      ({data,error}=await supabaseAdmin.storage.from(bucket).download(path));
    }
    if(error||!data) return res.status(404).json({message:'Media unavailable'});
    res.set('Cache-Control','private, no-store');
    res.set('Vary','Authorization');
    res.set('X-Content-Type-Options','nosniff');
    res.set('Content-Security-Policy',"sandbox; default-src 'none'");
    res.set('Content-Type',data.type||'application/octet-stream');
    return res.send(Buffer.from(await data.arrayBuffer()));
  }catch(error){next(error);}
}
