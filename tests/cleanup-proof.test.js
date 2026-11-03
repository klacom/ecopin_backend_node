import {jest} from '@jest/globals';
const rpc=jest.fn(),upload=jest.fn(),remove=jest.fn(),download=jest.fn(),from=jest.fn(()=>({upload,remove,download})),redact=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc,storage:{from}}}));
jest.unstable_mockModule('../src/services/cleanup-proof-image.service.js',()=>({redactCleanupImage:redact,
 normalizeRedactions:(v,n)=>{if(!Array.isArray(v))throw new Error('Provide hidden areas for each photo');const p=v.length===0?Array.from({length:n},()=>[]):v;if(p.length!==n)throw new Error('Provide hidden areas for every photo');return p;},
 storedRedactions:p=>p}));
const c=await import('../src/controllers/cleanup-proof.controller.js');
const id='a0900000-0000-4000-8000-000000000001',proofId='d0900000-0000-4000-8000-000000000001';
const ref=(bucket,slot,n)=>`storage://${encodeURIComponent(bucket)}/${id}/${slot}/${n}.jpg`;
const src=(over={})=>({report_id:id,version:3,fingerprint:'fp',publication_id:null,completed_at:'2026-11-02T04:00:00Z',
 before_urls:[ref('Cleanup Originals','before','b1'),ref('Cleanup Originals','before','b2')],after_urls:[ref('Cleanup Originals','after','a1')],...over});
const response=()=>({status:jest.fn().mockReturnThis(),json:jest.fn(),set:jest.fn(),type:jest.fn().mockReturnThis(),send:jest.fn()});
const body=(over={})=>({version:3,fingerprint:'fp',privacy_checked:true,public_notes:'Cleared.',redactions:{before:[[],[]],after:[[]]},publication_id:null,...over});
const publish=async(b,user={id:'officer'})=>{const res=response(),next=jest.fn();await c.publishCleanupProof({params:{id},body:b,user},res,next);return {res,next};};
beforeEach(()=>{jest.resetAllMocks();from.mockReturnValue({upload,remove,download});
 redact.mockResolvedValue(Buffer.from('redacted'));upload.mockResolvedValue({error:null});remove.mockResolvedValue({});
 download.mockResolvedValue({data:{arrayBuffer:async()=>new TextEncoder().encode('bytes').buffer},error:null});});
const ownerRpc=(owner='citizen')=>rpc.mockImplementation(async name=>name==='read_report_identity_context'?{data:[{id,user_id:owner}],error:null}:name==='read_cleanup_proof_source'?{data:src(),error:null}:{data:null,error:null});

test('owner routes expose only the owner\'s own photos, never a reviewed claim',async()=>{
 ownerRpc();const res=response(),next=jest.fn();await c.getOwnerCleanupProof({params:{id},user:{id:'citizen'}},res,next);
 const proof=res.json.mock.calls[0][0].proof;expect(proof.owner_only).toBe(true);expect(proof.before_urls).toHaveLength(2);expect(proof.after_urls).toHaveLength(1);expect(proof.verified_at).toBeUndefined();
 expect(res.set).toHaveBeenCalledWith('Cache-Control','private, no-store');
});
test.each([['another citizen'],['signed-out']])('%s cannot read owner photos and learns nothing about their count',async who=>{
 ownerRpc('someone-else');const res=response(),next=jest.fn();
 await c.getOwnerCleanupProofImage({params:{id,slot:'before',index:'9'},user:who==='signed-out'?undefined:{id:'citizen'}},res,next);
 expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:who==='signed-out'?401:404}));expect(res.send).not.toHaveBeenCalled();expect(download).not.toHaveBeenCalled();
});
test.each([['sideways',undefined],['before','-1'],['before','01'],['before','100'],['before','1.5']])('invalid slot/index %s/%s is rejected before storage',async(slot,index)=>{
 rpc.mockResolvedValue({data:src(),error:null});const res=response(),next=jest.fn();
 await c.getCleanupProofOriginal({params:{id,slot,index},user:{id:'officer'}},res,next);
 expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:400}));expect(download).not.toHaveBeenCalled();
});
test('a missing photo index is a 404 after authorisation, and originals are redacted-of-metadata before sending',async()=>{
 rpc.mockResolvedValue({data:src(),error:null});
 let res=response(),next=jest.fn();await c.getCleanupProofOriginal({params:{id,slot:'after',index:'1'},user:{id:'officer'}},res,next);
 expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:404}));
 res=response();next=jest.fn();await c.getCleanupProofOriginal({params:{id,slot:'before',index:'1'},user:{id:'officer'}},res,next);
 expect(download).toHaveBeenCalledWith(`${id}/before/b2.jpg`);expect(redact).toHaveBeenCalledWith(expect.any(Buffer),[]);expect(res.send).toHaveBeenCalled();
});
test.each([[{privacy_checked:false}],[{public_notes:'  '}],[{public_notes:'x'.repeat(2001)}],[{version:'3'}],[{fingerprint:undefined}]])('publication without a complete privacy review is refused: %j',async over=>{
 const {next}=await publish(body(over));expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:400}));expect(rpc).not.toHaveBeenCalled();expect(upload).not.toHaveBeenCalled();
});
test.each([[{version:4}],[{fingerprint:'old'}],[{publication_id:proofId}]])('a stale review is a 409 before any image is processed: %j',async over=>{
 rpc.mockResolvedValueOnce({data:src(),error:null});const {next}=await publish(body(over));
 expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:409}));expect(redact).not.toHaveBeenCalled();expect(upload).not.toHaveBeenCalled();
});
test.each([[{before:[[]],after:[[]]}],[{before:[[],[]],after:[[],[]]}],[{before:[[],[]]}],[{before:'x',after:[[]]}]])('a review that does not cover every photo is refused with nothing stored: %j',async redactions=>{
 rpc.mockResolvedValueOnce({data:src(),error:null});const {next}=await publish(body({redactions}));
 expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:400}));expect(upload).not.toHaveBeenCalled();expect(rpc).toHaveBeenCalledTimes(1);
});
test('an incomplete cleanup cannot be published',async()=>{
 rpc.mockResolvedValueOnce({data:src({completed_at:null}),error:null});const {next}=await publish(body());
 expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:409}));expect(upload).not.toHaveBeenCalled();
});
test('every photo of both slots gets its own redacted private copy, then one atomic publication',async()=>{
 rpc.mockResolvedValueOnce({data:src(),error:null}).mockResolvedValueOnce({data:{id:proofId,verified_at:'2026-11-03T00:00:00Z'},error:null});
 const rect=[{x:0.1,y:0.1,width:0.2,height:0.2}];
 const {res,next}=await publish(body({redactions:{before:[rect,[]],after:[[]]},actor:'attacker'}));
 expect(next).not.toHaveBeenCalled();expect(redact).toHaveBeenCalledTimes(3);expect(redact.mock.calls[0][1]).toEqual(rect);expect(redact.mock.calls[1][1]).toEqual([]);
 expect(from).toHaveBeenCalledWith('Cleanup Proof');expect(upload).toHaveBeenCalledTimes(3);
 const [name,args]=rpc.mock.calls[1];expect(name).toBe('publish_cleanup_proof_photos');expect(args.actor).toBe('officer');
 expect(args.before_paths).toHaveLength(2);expect(args.after_paths).toHaveLength(1);
 for(const p of [...args.before_paths,...args.after_paths])expect(p).toMatch(new RegExp(`^${id}/(before|after)/[a-f0-9-]+\\.jpg$`));
 expect(new Set([...args.before_paths,...args.after_paths]).size).toBe(3);expect(remove).not.toHaveBeenCalled();
 expect(res.json).toHaveBeenCalledWith({verified_at:'2026-11-03T00:00:00Z',id:proofId});
});
test.each([[{code:'40001'},409],[{code:'42501'},403],[{code:'22023'},400]])('a rejected publication (%j) removes every stored copy and reports %i',async(error,status)=>{
 rpc.mockResolvedValueOnce({data:src(),error:null}).mockResolvedValueOnce({data:null,error});
 const {next}=await publish(body());expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:status}));
 expect(remove).toHaveBeenCalledTimes(1);expect(remove.mock.calls[0][0]).toHaveLength(3);
});
test('a storage failure part-way removes the copies already stored and publishes nothing',async()=>{
 rpc.mockResolvedValueOnce({data:src(),error:null});upload.mockResolvedValueOnce({error:null}).mockResolvedValueOnce({error:{message:'x'}});
 const {next}=await publish(body());expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:503}));
 expect(rpc).toHaveBeenCalledTimes(1);expect(remove.mock.calls[0][0]).toHaveLength(1);
});
test('public delivery serves only the published, current, indexed copy from the proof bucket',async()=>{
 rpc.mockResolvedValue({data:{id:proofId,before_paths:[`${id}/before/p1.jpg`,`${id}/before/p2.jpg`],after_paths:[`${id}/after/p3.jpg`]},error:null});
 let res=response(),next=jest.fn();await c.getPublicCleanupProofImage({params:{id,proofId,slot:'before',index:'1'}},res,next);
 expect(from).toHaveBeenCalledWith('Cleanup Proof');expect(download).toHaveBeenCalledWith(`${id}/before/p2.jpg`);expect(res.set).toHaveBeenCalledWith('X-Content-Type-Options','nosniff');
 for(const params of [{proofId:'other',slot:'before',index:'0'},{proofId,slot:'after',index:'1'},{proofId,slot:'original',index:'0'}]){
  jest.clearAllMocks();res=response();next=jest.fn();await c.getPublicCleanupProofImage({params:{id,...params}},res,next);
  expect(next).toHaveBeenCalled();expect(res.send).not.toHaveBeenCalled();expect(download).not.toHaveBeenCalled();
 }
});
test('with no current publication the public proof is empty and images are 404',async()=>{
 rpc.mockResolvedValue({data:null,error:null});let res=response();await c.getPublicCleanupProof({params:{id}},res,jest.fn());expect(res.json).toHaveBeenCalledWith({proof:null});
 const next=jest.fn();await c.getPublicCleanupProofImage({params:{id,proofId,slot:'before'}},response(),next);expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:404}));
});
test('the public listing exposes counts and links, never paths or crew notes',async()=>{
 rpc.mockResolvedValue({data:{id:proofId,public_notes:'Cleared.',completed_at:'c',verified_at:'v',before_paths:['p/1.jpg','p/2.jpg'],after_paths:['p/3.jpg'],action_notes:'CREW'},error:null});
 const res=response();await c.getPublicCleanupProof({params:{id}},res,jest.fn());const out=JSON.stringify(res.json.mock.calls[0][0]);
 expect(res.json.mock.calls[0][0].proof.before_urls).toHaveLength(2);expect(out).not.toContain('.jpg');expect(out).not.toContain('CREW');
});
test('a failed original download is reported as JSON with a storage category, never after the image type is set',async()=>{
 rpc.mockResolvedValue({data:src(),error:null});download.mockResolvedValueOnce({data:null,error:{message:'Object not found'}});
 const res=response(),next=jest.fn();await c.getCleanupProofOriginal({params:{id,slot:'before',index:'0'},user:{id:'officer'}},res,next);
 expect(res.type).not.toHaveBeenCalled();expect(res.send).not.toHaveBeenCalled();
 expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:404,publicCode:'storage_unavailable'}));
});
test('a storage failure while storing reviewed copies carries the storage category',async()=>{
 rpc.mockResolvedValueOnce({data:src(),error:null});upload.mockResolvedValueOnce({error:{message:'x'}});
 const {next}=await publish(body());expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:503,publicCode:'storage_unavailable'}));
});
