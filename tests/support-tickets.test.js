import {jest} from '@jest/globals';
const abortSignal=jest.fn(),rpc=jest.fn(()=>({abortSignal}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const c=await import('../src/controllers/support-ticket.controller.js');
const response=()=>({status:jest.fn().mockReturnThis(),json:jest.fn(),set:jest.fn()});
const id='11111111-1111-4111-8111-111111111111',valid={category:'status_inquiry',description:'Please check my report status.'};
beforeEach(()=>{jest.clearAllMocks();abortSignal.mockResolvedValue({data:null,error:null});});

test.each([
 [{category:'nope',description:valid.description}],[{category:valid.category,description:'short'}],
 [{...valid,description:'x'.repeat(2001)}],[{...valid,report_id:'not-a-uuid'}],[undefined],
])('invalid ticket creation is rejected before storage: %j',async body=>{
 const res=response();await c.createTicket({body,user:{id:'citizen'}},res);
 expect(res.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();
});
test('creation binds the session actor and ignores client-supplied identity',async()=>{
 abortSignal.mockResolvedValueOnce({data:{reference:'TCK-001000'},error:null});
 const res=response();await c.createTicket({body:{...valid,description:`  ${valid.description}  `,actor:'attacker',citizen_id:'attacker'},user:{id:'citizen'}},res);
 expect(rpc).toHaveBeenCalledWith('create_support_ticket',{actor:'citizen',ticket_category:'status_inquiry',ticket_description:valid.description,ticket_report_id:null});
 expect(res.status).toHaveBeenCalledWith(201);expect(res.set).toHaveBeenCalledWith('Cache-Control','private, no-store');
});
test.each([['53400',429],['P0002',404],['42501',403],['22023',400],['XX000',503]])('storage error %s maps to %i',async(code,status)=>{
 abortSignal.mockResolvedValueOnce({data:null,error:{code}});
 const res=response();await c.createTicket({body:valid,user:{id:'citizen'}},res);expect(res.status).toHaveBeenCalledWith(status);
});
test('a storage exception is a retryable 503, not a fabricated ticket',async()=>{
 abortSignal.mockRejectedValueOnce(new Error('timeout'));
 const res=response();await c.createTicket({body:valid,user:{id:'citizen'}},res);
 expect(res.status).toHaveBeenCalledWith(503);expect(res.json).toHaveBeenCalledWith({error:'Your ticket could not be saved. Please try again.'});
});
test('citizens read tickets only through their own actor and reference',async()=>{
 abortSignal.mockResolvedValueOnce({data:{reference:'TCK-001000'},error:null});
 const res=response();await c.getMyTicket({params:{reference:'TCK-001000'},user:{id:'citizen'}},res);
 expect(rpc).toHaveBeenCalledWith('read_my_support_ticket',{actor:'citizen',ticket_ref:'TCK-001000'});
 const bad=response();await c.getMyTicket({params:{reference:'../x'},user:{id:'citizen'}},bad);
 expect(bad.status).toHaveBeenCalledWith(404);expect(rpc).toHaveBeenCalledTimes(1);
});
test('a ticket owned by another citizen is reported as not found',async()=>{
 abortSignal.mockResolvedValueOnce({data:null,error:{code:'P0002'}});
 const res=response();await c.getMyTicket({params:{reference:'TCK-001000'},user:{id:'other'}},res);
 expect(res.status).toHaveBeenCalledWith(404);expect(res.json).not.toHaveBeenCalledWith(expect.objectContaining({reference:expect.anything()}));
});
test.each([{limit:'0'},{limit:'101'},{limit:'x'},{before_created:'2026-01-01T00:00:00Z'},{before_created:'bad',before_id:id},{status:'deleted'}])('invalid queue page is rejected: %j',async query=>{
 const res=response();await c.listTicketQueue({query,user:{id:'officer'}},res);expect(res.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();
});
test('queue reads bind the staff actor, filter and cursor',async()=>{
 abortSignal.mockResolvedValueOnce({data:{tickets:[]},error:null});
 const res=response();await c.listTicketQueue({query:{status:'open',limit:'20',before_created:'2026-01-01T00:00:00Z',before_id:id},user:{id:'officer'}},res);
 expect(rpc).toHaveBeenCalledWith('read_support_ticket_queue',{actor:'officer',status_filter:'open',cursor_created:'2026-01-01T00:00:00Z',cursor_id:id,page_limit:20});
});
test('a queue read failure is an error rather than an empty queue',async()=>{
 abortSignal.mockResolvedValueOnce({data:null,error:{code:'PGRST202'}});
 const res=response();await c.listTicketQueue({query:{},user:{id:'officer'}},res);
 expect(res.status).toHaveBeenCalledWith(503);expect(res.json).not.toHaveBeenCalledWith(expect.objectContaining({tickets:expect.anything()}));
});
test.each([{id:'bad',body:{response:'ok',status:'resolved'}},{id,body:{response:'ok',status:'open'}},{id,body:{response:'  ',status:'resolved'}},{id,body:{response:'x'.repeat(2001),status:'closed'}}])('invalid reply is rejected: %j',async({id:ticket,body})=>{
 const res=response();await c.respondToTicket({params:{id:ticket},body,user:{id:'officer'}},res);expect(res.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();
});
test('replies bind the authenticated staff actor',async()=>{
 abortSignal.mockResolvedValueOnce({data:{reference:'TCK-001000'},error:null});
 const res=response();await c.respondToTicket({params:{id},body:{response:' Fixed. ',status:'resolved',actor:'attacker'},user:{id:'officer'}},res);
 expect(rpc).toHaveBeenCalledWith('respond_support_ticket',{actor:'officer',ticket_id:id,reply:'Fixed.',new_status:'resolved'});
});
test('an unsaved reply is an error the staff member can retry',async()=>{
 abortSignal.mockRejectedValueOnce(new Error('timeout'));
 const res=response();await c.respondToTicket({params:{id},body:{response:'ok',status:'closed'},user:{id:'officer'}},res);
 expect(res.status).toHaveBeenCalledWith(503);expect(res.json).toHaveBeenCalledWith({error:'Your reply could not be saved. Please try again.'});
});
