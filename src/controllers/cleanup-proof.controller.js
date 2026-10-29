import {randomUUID} from 'node:crypto';
import {supabaseAdmin as db} from '../config/supabase.config.js';
import {parseStorageReference} from '../services/storage-reference.js';
import {redactCleanupImage,validateRedactions} from '../services/cleanup-proof-image.service.js';

const fail=(message,statusCode=400)=>Object.assign(new Error(message),{statusCode});
async function source(id){
 const {data,error}=await db.rpc('read_cleanup_proof_source',{report_id:id});
 if(error)throw fail('Cleanup proof review is temporarily unavailable',503);
 if(!data)throw fail('Report not found',404);
 return data;
}
async function original(url){
 const ref=parseStorageReference(url,process.env.SUPABASE_URL||process.env.NEXT_PUBLIC_SUPABASE_URL);
 if(ref){
  const {data,error}=await db.storage.from(ref.bucket).download(ref.path);
  if(error||!data)throw fail('Original photo unavailable',404);
  return Buffer.from(await data.arrayBuffer());
 }
 const parsed=new URL(url);
 if(parsed.origin!=='https://res.cloudinary.com'||parsed.username||parsed.password||
  !process.env.CLOUDINARY_CLOUD_NAME||!parsed.pathname.startsWith(`/${process.env.CLOUDINARY_CLOUD_NAME}/image/upload/`))throw fail('Unsupported original photo reference',409);
 const response=await fetch(parsed,{redirect:'error',signal:AbortSignal.timeout(15000)});
 if(!response.ok)throw fail('Original photo unavailable',404);
 const chunks=[];let size=0;
 for await(const chunk of response.body){size+=chunk.length;if(size>10485760)throw fail('Original photo is too large');chunks.push(chunk);}
 return Buffer.concat(chunks);
}
export async function getCleanupProofSource(req,res,next){try{
 res.set('Cache-Control','private, no-store');res.json(await source(req.params.id));
}catch(error){next(error);}}
export async function getCleanupProofOriginal(req,res,next){try{
 if(!['before','after'].includes(req.params.slot))throw fail('Invalid photo slot');
 const data=await source(req.params.id),url=data[`${req.params.slot}_url`];
 if(!url)throw fail('Original photo unavailable',404);
 res.set('Cache-Control','private, no-store');res.type('image/jpeg').send(await redactCleanupImage(await original(url),[]));
}catch(error){next(error);}}
export async function publishCleanupProof(req,res,next){
 const paths=[];
 try{
  const {version,fingerprint,redactions,public_notes,privacy_checked,publication_id}=req.body;
  if(!Number.isSafeInteger(version)||typeof fingerprint!=='string'||privacy_checked!==true||
   typeof public_notes!=='string'||!public_notes.trim()||public_notes.length>2000)throw fail('Review both photos, confirm privacy and provide public action notes');
  validateRedactions(redactions?.before);validateRedactions(redactions?.after);
  const data=await source(req.params.id);
  if(data.version!==version||data.fingerprint!==fingerprint||(data.publication_id??null)!==(publication_id??null))throw fail('Proof changed; reload before reviewing',409);
  if(!data.before_url||!data.after_url||!data.completed_at)throw fail('Completed cleanup with Before and After photos is required',409);
  for(const slot of ['before','after']){
   const buffer=await redactCleanupImage(await original(data[`${slot}_url`]),redactions[slot]);
   const path=`${data.report_id.toLowerCase()}/${slot}/${randomUUID()}.jpg`;
   const {error}=await db.storage.from('Cleanup Proof').upload(path,buffer,{contentType:'image/jpeg',upsert:false});
   if(error)throw fail('Redacted proof could not be stored',503);paths.push(path);
  }
  const {data:proof,error}=await db.rpc('publish_cleanup_proof',{report_id:req.params.id,actor:req.user.id,
   expected_version:version,expected_fingerprint:fingerprint,before_path:paths[0],after_path:paths[1],public_notes,expected_publication_id:publication_id??null,redactions});
  if(error)throw fail(error.code==='42501'?'Review is not permitted':error.code==='40001'?'Proof changed; reload before reviewing':'Proof could not be approved',error.code==='42501'?403:error.code==='40001'?409:400);
  res.set('Cache-Control','private, no-store');res.json({verified_at:proof.verified_at,id:proof.id});
 }catch(error){if(paths.length)await db.storage.from('Cleanup Proof').remove(paths).catch(()=>{});next(error);}
}
export async function getPublicCleanupProof(req,res,next){try{
 const {data,error}=await db.rpc('read_cleanup_proof',{report_id:req.params.id});
 if(error)throw fail('Cleanup proof is temporarily unavailable',503);
 res.set('Cache-Control','no-store');
 if(!data)return res.json({proof:null});
 res.json({proof:{id:data.id,public_notes:data.public_notes,completed_at:data.completed_at,verified_at:data.verified_at,
  before_url:`/api/reports/${req.params.id}/cleanup-proof/public/${data.id}/before`,after_url:`/api/reports/${req.params.id}/cleanup-proof/public/${data.id}/after`}});
}catch(error){next(error);}}
export async function getPublicCleanupProofImage(req,res,next){try{
 if(!['before','after'].includes(req.params.slot))throw fail('Invalid photo slot');
 const {data,error}=await db.rpc('read_cleanup_proof',{report_id:req.params.id});
 if(error)throw fail('Cleanup proof is temporarily unavailable',503);
 if(!data||data.id!==req.params.proofId)throw fail('Verified public proof unavailable',404);
 const {data:blob,error:downloadError}=await db.storage.from('Cleanup Proof').download(data[`${req.params.slot}_path`]);
 if(downloadError||!blob)throw fail('Verified public proof unavailable',404);
 res.set('Cache-Control','no-store');res.set('X-Content-Type-Options','nosniff');res.type('image/jpeg').send(Buffer.from(await blob.arrayBuffer()));
}catch(error){next(error);}}
