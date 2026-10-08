import { jest } from '@jest/globals';
const rpc=jest.fn();
let photo;
const from=jest.fn(()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:photo,error:null})})})}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc,from}}));
const {batchFcSync}=await import('../src/controllers/fc_sync.controller.js');
const {hashBuffer,checkPhotoDuplicate}=await import('../src/services/photo_dedup.service.js');
// Concurrency, authority, idempotence and audit assertions now execute against PostgreSQL
// in tests/sql/dispatch-regression.sql, instead of reproducing policy in a JS mock.
const operation={operation_id:'operation-1',operation_type:'fc.report.update_status',entity_id:'report-1',entity_type:'report',payload:{status:'in_progress'},base_version:4};
async function batch(operations){
 const res={statusCode:200,status(value){this.statusCode=value;return this;},json(value){this.body=value;return this;}};
 await batchFcSync({body:{operations},user:{id:'verified-user',role:'field_crew'}},res,error=>{throw error;});return res;
}
beforeEach(()=>{rpc.mockReset();from.mockClear();photo=null;});
test('forwards verified actor and exact version to the atomic RPC without a separate read',async()=>{
 rpc.mockResolvedValue({data:{status:'success',server_record:{fc_version:5}},error:null});
 const res=await batch([operation]);
 expect(rpc).toHaveBeenCalledWith('apply_fc_operation',{actor:'verified-user',...operation});
 expect(from).not.toHaveBeenCalled();expect(res.body.results[0].server_record.fc_version).toBe(5);
});
test('preserves authoritative conflict detail instead of treating a retry as success',async()=>{
 const conflict={status:'conflict',replayed:true,server_record:{fc_version:7},error_message:'Report version changed'};
 rpc.mockResolvedValue({data:conflict,error:null});
 expect((await batch([operation])).body.results).toEqual([conflict]);
});
test('one denied operation does not hide later results',async()=>{
 rpc.mockResolvedValueOnce({data:null,error:{code:'42501',message:'Report is not assigned to this crew'}})
  .mockResolvedValueOnce({data:{status:'success'},error:null});
 const res=await batch([operation,{...operation,operation_id:'operation-2'}]);
 expect(res.body.results.map(r=>r.status)).toEqual(['failed','success']);
 expect(res.body.results[0].error_message).toMatch(/not assigned/);
});
test.each([-1,1.5,'4',NaN])('rejects invalid version %s without contacting the database',async version=>{
 expect((await batch([{...operation,base_version:version}])).body.results[0].status).toBe('failed');expect(rpc).not.toHaveBeenCalled();
});
test('rejects missing operation ID without contacting the database',async()=>{
 expect((await batch([{...operation,operation_id:null}])).body.results[0].status).toBe('failed');expect(rpc).not.toHaveBeenCalled();
});
test('empty batch is accepted',async()=>{expect((await batch([])).body.results).toEqual([]);expect(rpc).not.toHaveBeenCalled();});
test('batch limit and payload shape are enforced',async()=>{
 expect((await batch(Array(51).fill(operation))).statusCode).toBe(400);expect((await batch({})).statusCode).toBe(400);expect(rpc).not.toHaveBeenCalled();
});
test('same photo content is deduplicated',async()=>{
 const hash=hashBuffer(Buffer.from('same-image'));photo={before_photo_hash:hash,before_photo_url:'https://cdn.example/photo'};
 expect(await checkPhotoDuplicate('reports','r','before',hash)).toEqual({isDuplicate:true,existingUrl:'https://cdn.example/photo'});
});
test('different photo content is preserved',async()=>{
 photo={before_photo_hash:hashBuffer(Buffer.from('first')),before_photo_url:'https://cdn.example/photo'};
 expect((await checkPhotoDuplicate('reports','r','before',hashBuffer(Buffer.from('second')))).isDuplicate).toBe(false);
});
test('empty photo slot accepts both distinct incoming photos',async()=>{
 photo={before_photo_hash:null,before_photo_url:null};
 expect((await checkPhotoDuplicate('reports','r','before',hashBuffer(Buffer.from('first')))).isDuplicate).toBe(false);
 expect((await checkPhotoDuplicate('reports','r','before',hashBuffer(Buffer.from('second')))).isDuplicate).toBe(false);
});
test('photo hashes have SHA256 form and stable content identity',()=>{
 expect(hashBuffer(Buffer.from('first'))).toMatch(/^[a-f0-9]{64}$/);
 expect(hashBuffer(Buffer.from('first'))).toBe(hashBuffer(Buffer.from('first')));
 expect(hashBuffer(Buffer.from('first'))).not.toBe(hashBuffer(Buffer.from('second')));
});
