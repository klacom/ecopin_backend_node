import {randomUUID} from 'node:crypto';
import {supabaseAdmin as db} from '../config/supabase.config.js';
import {parseStorageReference} from '../services/storage-reference.js';
import {redactCleanupImage,normalizeRedactions,storedRedactions} from '../services/cleanup-proof-image.service.js';

// Field crew can attach up to 5 photos to each slot (reports.before_photos / after_photos).
export const MAX_CLEANUP_PHOTOS_PER_SLOT=5;
const fail=(message,statusCode=400)=>Object.assign(new Error(message),{statusCode});
const slotParam=slot=>{if(!['before','after'].includes(slot))throw fail('Invalid photo slot');return slot;};
// An absent index is the first photo, which keeps the original /:slot routes working.
const indexParam=raw=>{
 if(raw===undefined)return 0;
 if(!/^(0|[1-9]\d?)$/.test(String(raw)))throw fail('Invalid photo index');
 return Number(raw);
};
// Authorization happens before this check so unauthorised callers cannot learn how many photos exist.
const pick=(list,index,message)=>{if(index>=list.length)throw fail(message,404);return list[index];};
// Source photos in upload order; a source that predates the list columns exposes only its single photo.
function sourceUrls(data,slot){
 const list=data[`${slot}_urls`],single=data[`${slot}_url`];
 const urls=Array.isArray(list)?list:single?[single]:[];
 return urls.filter(url=>typeof url==='string'&&url).slice(0,MAX_CLEANUP_PHOTOS_PER_SLOT);
}
function publishedPaths(data,slot){
 const list=data[`${slot}_paths`],single=data[`${slot}_path`];
 const paths=Array.isArray(list)&&list.length?list:single?[single]:[];
 return paths.filter(path=>typeof path==='string'&&path).slice(0,MAX_CLEANUP_PHOTOS_PER_SLOT);
}
const indexed=(base,count)=>Array.from({length:count},(_,index)=>`${base}/${index}`);

async function ownerSource(req){
 const id=req.params.id;
 if(!req.user?.id)throw fail('Authentication required',401);
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))throw fail('Report not found',404);
 // Identity context also resolves ownership of reports submitted anonymously.
 const {data,error}=await db.rpc('read_report_identity_context',{report_ids:[id]});
 if(error)throw fail('Cleanup photos are temporarily unavailable',503);
 if(!data?.some(row=>row.id.toLowerCase()===id.toLowerCase()&&row.user_id===req.user.id))throw fail('Report not found',404);
 return source(id);
}
export async function getOwnerCleanupProof(req,res,next){try{
 const data=await ownerSource(req);
 res.set('Cache-Control','private, no-store');res.set('Vary','Authorization');
 const before=sourceUrls(data,'before'),after=sourceUrls(data,'after');
 if(!before.length&&!after.length)return res.json({proof:null});
 // Owner-only pixels: never presented as officer-reviewed. Reviewed copies come from the public publication.
 const path=`/api/reports/${req.params.id}/cleanup-proof/owner`;
 res.json({proof:{id:'owner',owner_only:true,completed_at:data.completed_at,
  before_url:before.length?`${path}/before`:null,after_url:after.length?`${path}/after`:null,
  before_urls:indexed(`${path}/before`,before.length),after_urls:indexed(`${path}/after`,after.length)}});
}catch(error){next(error);}}
export async function getOwnerCleanupProofImage(req,res,next){try{
 const slot=slotParam(req.params.slot),index=indexParam(req.params.index);
 const data=await ownerSource(req),url=pick(sourceUrls(data,slot),index,'Cleanup photo unavailable');
 const image=await redactCleanupImage(await original(url),[]);
 res.set('Cache-Control','private, no-store');res.set('Vary','Authorization');
 res.set('X-Content-Type-Options','nosniff');res.type('image/jpeg').send(image);
}catch(error){next(error);}}
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
 const slot=slotParam(req.params.slot),index=indexParam(req.params.index);
 const data=await source(req.params.id),url=pick(sourceUrls(data,slot),index,'Original photo unavailable');
 res.set('Cache-Control','private, no-store');res.type('image/jpeg').send(await redactCleanupImage(await original(url),[]));
}catch(error){next(error);}}
export async function publishCleanupProof(req,res,next){
 const paths={before:[],after:[]};
 try{
  const {version,fingerprint,redactions,public_notes,privacy_checked,publication_id}=req.body;
  if(!Number.isSafeInteger(version)||typeof fingerprint!=='string'||privacy_checked!==true||
   typeof public_notes!=='string'||!public_notes.trim()||public_notes.length>2000)throw fail('Review every photo, confirm privacy and provide public action notes');
  const data=await source(req.params.id);
  if(data.version!==version||data.fingerprint!==fingerprint||(data.publication_id??null)!==(publication_id??null))throw fail('Proof changed; reload before reviewing',409);
  const urls={before:sourceUrls(data,'before'),after:sourceUrls(data,'after')};
  if(!urls.before.length||!urls.after.length||!data.completed_at)throw fail('Completed cleanup with Before and After photos is required',409);
  // Each photo is redacted with its own rectangles; none is published unreviewed.
  const regions={};
  for(const slot of ['before','after']){
   try{regions[slot]=normalizeRedactions(redactions?.[slot],urls[slot].length);}catch(error){throw fail(error.message);}
  }
  for(const slot of ['before','after'])for(const [index,url] of urls[slot].entries()){
   const buffer=await redactCleanupImage(await original(url),regions[slot][index]);
   const path=`${data.report_id.toLowerCase()}/${slot}/${randomUUID()}.jpg`;
   const {error}=await db.storage.from('Cleanup Proof').upload(path,buffer,{contentType:'image/jpeg',upsert:false});
   if(error)throw fail('Redacted proof could not be stored',503);paths[slot].push(path);
  }
  const {data:proof,error}=await db.rpc('publish_cleanup_proof_photos',{report_id:req.params.id,actor:req.user.id,
   expected_version:version,expected_fingerprint:fingerprint,before_paths:paths.before,after_paths:paths.after,public_notes,expected_publication_id:publication_id??null,
   redactions:{before:storedRedactions(regions.before),after:storedRedactions(regions.after)}});
  if(error)throw fail(error.code==='42501'?'Review is not permitted':error.code==='40001'?'Proof changed; reload before reviewing':'Proof could not be approved',error.code==='42501'?403:error.code==='40001'?409:400);
  res.set('Cache-Control','private, no-store');res.json({verified_at:proof.verified_at,id:proof.id});
 }catch(error){
  const stored=[...paths.before,...paths.after];
  if(stored.length)await db.storage.from('Cleanup Proof').remove(stored).catch(()=>{});next(error);
 }
}
export async function getPublicCleanupProof(req,res,next){try{
 const {data,error}=await db.rpc('read_cleanup_proof',{report_id:req.params.id});
 if(error)throw fail('Cleanup proof is temporarily unavailable',503);
 res.set('Cache-Control','no-store');
 if(!data)return res.json({proof:null});
 const path=`/api/reports/${req.params.id}/cleanup-proof/public/${data.id}`;
 res.json({proof:{id:data.id,public_notes:data.public_notes,completed_at:data.completed_at,verified_at:data.verified_at,
  before_url:`${path}/before`,after_url:`${path}/after`,
  before_urls:indexed(`${path}/before`,Math.max(1,publishedPaths(data,'before').length)),
  after_urls:indexed(`${path}/after`,Math.max(1,publishedPaths(data,'after').length))}});
}catch(error){next(error);}}
export async function getPublicCleanupProofImage(req,res,next){try{
 const slot=slotParam(req.params.slot),index=indexParam(req.params.index);
 const {data,error}=await db.rpc('read_cleanup_proof',{report_id:req.params.id});
 if(error)throw fail('Cleanup proof is temporarily unavailable',503);
 if(!data||data.id!==req.params.proofId)throw fail('Verified public proof unavailable',404);
 const path=pick(publishedPaths(data,slot),index,'Verified public proof unavailable');
 const {data:blob,error:downloadError}=await db.storage.from('Cleanup Proof').download(path);
 if(downloadError||!blob)throw fail('Verified public proof unavailable',404);
 res.set('Cache-Control','no-store');res.set('X-Content-Type-Options','nosniff');res.type('image/jpeg').send(Buffer.from(await blob.arrayBuffer()));
}catch(error){next(error);}}
