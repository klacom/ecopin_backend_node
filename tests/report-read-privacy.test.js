import {jest} from '@jest/globals';
const from=jest.fn(),rpc=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{from,rpc}}));
const {getReportById,getPublicReports,getReportsByClusterId}=await import('../src/controllers/report-read.controller.js');
const {canReadReportEvidence}=await import('../src/services/report-access.service.js');
function query(data,error=null){const q={};for(const name of ['select','eq','order','limit','range','is'])q[name]=jest.fn(()=>q);q.maybeSingle=jest.fn(async()=>({data,error}));q.then=(resolve,reject)=>Promise.resolve({data,error}).then(resolve,reject);return q;}
function response(){return {statusCode:200,headers:{},status(code){this.statusCode=code;return this;},json(body){this.body=body;return this;},set(name,value){this.headers[name]=value;return this;}};}
const privateRow={id:'11111111-1111-4111-8111-111111111111',user_id:'owner',notes:'internal secret',validation_status:'approved',location:'precise'};
const publicRow={id:'11111111-1111-4111-8111-111111111111',title:'Public title',validation_status:'approved',location_precision:'exact'};
beforeEach(()=>{from.mockReset();rpc.mockReset();rpc.mockResolvedValue({data:null,error:null});});
test('ordinary public detail excludes identity and logs despite service-key reads',async()=>{
 from.mockReturnValue(query(publicRow));
 const res=response();await getReportById({params:{id:'11111111-1111-4111-8111-111111111111'},user:{id:'stranger',role:'citizen'}},res,e=>{throw e;});
 expect(res.body).toEqual({...publicRow,response_logs:[]});expect(from).toHaveBeenCalledWith('public_reports');
 expect(rpc).toHaveBeenCalledWith('read_authorized_report_detail',{actor:'stranger',report_id:'11111111-1111-4111-8111-111111111111'});
});
test('hidden report returns not found without revealing its existence',async()=>{
 from.mockReturnValue(query(null));const res=response();
 await getReportById({params:{id:'11111111-1111-4111-8111-111111111111'},user:{id:'stranger',role:'citizen'}},res,e=>{throw e;});
 expect(res.statusCode).toBe(404);expect(res.body).not.toHaveProperty('notes');
});
test.each(['officer','admin','citizen','field_crew'])('database-authorized %s retains details',async(role)=>{
 rpc.mockResolvedValue({data:privateRow,error:null});from.mockReturnValue(query([]));
 const res=response();await getReportById({params:{id:'11111111-1111-4111-8111-111111111111'},user:{id:'verified-viewer',role}},res,e=>{throw e;});
 expect(res.body.notes).toBe('internal secret');
 expect(rpc).toHaveBeenCalledWith('read_authorized_report_detail',{actor:'verified-viewer',report_id:'11111111-1111-4111-8111-111111111111'});
 expect(from).toHaveBeenCalledWith('response_log');expect(from).not.toHaveBeenCalledWith('reports_view');
});
test('a role label cannot override a denied atomic read',async()=>{
 from.mockReturnValue(query(publicRow));const res=response();
 await getReportById({params:{id:'11111111-1111-4111-8111-111111111111'},user:{id:'stranger',role:'admin'}},res,e=>{throw e;});
 expect(res.body.notes).toBeUndefined();expect(res.body.user_id).toBeUndefined();
});
test('anonymous request never calls privileged detail RPC',async()=>{
 from.mockReturnValue(query(publicRow));const res=response();
 await getReportById({params:{id:'11111111-1111-4111-8111-111111111111'}},res,e=>{throw e;});expect(rpc).not.toHaveBeenCalled();expect(res.body.response_logs).toEqual([]);
});
test('detail database error fails closed without public fallback',async()=>{
 const error={message:'permission error'};rpc.mockResolvedValue({data:null,error});const next=jest.fn();
 await getReportById({params:{id:'11111111-1111-4111-8111-111111111111'},user:{id:'viewer'}},response(),next);
 expect(next).toHaveBeenCalledWith(error);expect(from).not.toHaveBeenCalled();
});
test('public feed uses safe columns and deterministic bounded pagination',async()=>{
 const q=query([publicRow]);from.mockReturnValue(q);const res=response();
 await getPublicReports({query:{limit:'25',page:'2'}},res,e=>{throw e;});
 expect(from).toHaveBeenCalledWith('public_reports');expect(q.select.mock.calls[0][0]).not.toBe('*');
 expect(q.range).toHaveBeenCalledWith(25,50);expect(q.order).toHaveBeenCalledWith('created_at',{ascending:false});expect(q.order).toHaveBeenCalledWith('id',{ascending:false});
 expect(res.body).toEqual([publicRow]);expect(res.headers['X-Has-More']).toBe('false');
});
test.each([{limit:'501'},{limit:'0'},{limit:'2.5'},{page:'-1'},{page:'nope'}])('invalid bounds rejected before database query: %p',async(params)=>{
 const res=response();await getPublicReports({query:params},res,e=>{throw e;});
 expect(res.statusCode).toBe(400);expect(from).not.toHaveBeenCalled();
});
test('citizen cluster read uses safe projection',async()=>{
 const q=query([publicRow]);from.mockReturnValue(q);const res=response();
 await getReportsByClusterId({params:{clusterId:'cluster'},query:{},user:{id:'stranger',role:'citizen'}},res,e=>{throw e;});
 expect(from).toHaveBeenCalledWith('public_reports');expect(q.eq).toHaveBeenCalledWith('cluster_id','cluster');expect(res.body).toEqual([publicRow]);
});
test('public private-property evidence is denied while authorized detail retains it',()=>{
 expect(canReadReportEvidence({detail:false,report:{location_precision:'approximate'}})).toBe(false);
 expect(canReadReportEvidence({detail:false,report:publicRow})).toBe(true);
 expect(canReadReportEvidence({detail:true,report:privateRow})).toBe(true);
 expect(canReadReportEvidence(null)).toBe(false);
});
