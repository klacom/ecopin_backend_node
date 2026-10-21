import {jest} from '@jest/globals';
const from=jest.fn(),rpc=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{from,rpc}}));
jest.unstable_mockModule('../src/config/index.js',()=>({NEXT_PUBLIC_SUPABASE_URL:'https://synthetic.invalid',CLEANUP_TASK_PHOTOS_STORAGE_PATH:'Cleanup Task Photos',BEFORE_AFTER_PHOTO_FILE_SIZE:1024}));
jest.unstable_mockModule('../src/services/photo_dedup.service.js',()=>({hashBuffer:jest.fn(),checkPhotoDuplicate:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/dispatchPlanner.service.js',()=>({generateDispatchPlan:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/dispatchCommit.service.js',()=>({commitAndRoutePlan:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/taskFeedback.service.js',()=>({processTaskFeedback:jest.fn()}));
const {getAllCleanupTasks,getCleanupTaskById,getTasksByClusterId}=await import('../src/controllers/cleanup_task.controller.js');
function response(){return {code:200,headers:{},status(code){this.code=code;return this},set(name,value){this.headers[name]=value;return this},json(body){this.body=body;return this}};}
const summary={id:'task',status:'completed',title:'Cleanup progress',access_level:'summary',before_photo_url:null};
beforeEach(()=>{from.mockReset();rpc.mockReset();rpc.mockResolvedValue({data:[summary],error:null});});
test('citizen cluster route uses atomic authorization and preserves its limited summary',async()=>{
 const res=response();
 await getTasksByClusterId({params:{clusterId:'cluster'},query:{},user:{id:'citizen',role:'citizen'}},res,e=>{throw e});
 expect(rpc).toHaveBeenCalledWith('read_authorized_cleanup_tasks',expect.objectContaining({actor:'citizen',p_cluster_id:'cluster',p_task_id:null}));
 expect(from).not.toHaveBeenCalled();expect(res.body).toEqual([summary]);expect(res.headers['Cache-Control']).toBe('private, no-store');
});
test('spoofed or stale request role cannot override database denial',async()=>{
 rpc.mockResolvedValue({data:[],error:null});const res=response();
 await getCleanupTaskById({params:{id:'task'},query:{},user:{id:'stranger',role:'admin'}},res,e=>{throw e});
 expect(res.code).toBe(404);expect(from).not.toHaveBeenCalled();
 expect(rpc).toHaveBeenCalledWith('read_authorized_cleanup_tasks',expect.objectContaining({actor:'stranger',p_task_id:'task'}));
});
test('crew history summaries are not enriched with privileged report fields',async()=>{
 const res=response();await getAllCleanupTasks({query:{},user:{id:'crew',role:'field_crew'}},res,e=>{throw e});
 expect(res.body).toEqual([summary]);expect(res.body[0]).not.toHaveProperty('report_claim_generations');expect(from).not.toHaveBeenCalled();
});
test('authorized task detail keeps the database projection and claim dictionary',async()=>{
 const detail={...summary,access_level:'detail',description:'Authorized details',reports:[{id:'report'}],report_claim_generations:{report:3}};
 rpc.mockResolvedValue({data:[detail],error:null});const res=response();
 await getCleanupTaskById({params:{id:'task'},query:{},user:{id:'staff'}},res,e=>{throw e});expect(res.body).toEqual(detail);
});
test('task list uses bounded stable page contract with sentinel',async()=>{
 rpc.mockResolvedValue({data:[summary,{...summary,id:'sentinel'}],error:null});const res=response();
 await getAllCleanupTasks({query:{limit:'1',page:'2',assigned_to_me:'true'},user:{id:'staff'}},res,e=>{throw e});
 expect(rpc).toHaveBeenCalledWith('read_authorized_cleanup_tasks',expect.objectContaining({p_assigned_only:true,p_limit:2,p_offset:1}));
 expect(res.body).toEqual([summary]);expect(res.headers['X-Has-More']).toBe('true');
});

test('authorized detail loads only its assigned team and member names',async()=>{
 const detail={id:'task',access_level:'detail',assigned_field_crew_id:'team',assigned_crew_ids:['member','member']};
 rpc.mockResolvedValue({data:[detail],error:null});
 const eq=jest.fn().mockReturnValue({maybeSingle:async()=>({data:{id:'team',name:'Crew Alpha'}})});
 const memberIn=jest.fn().mockResolvedValue({data:[{id:'member',full_name:'Alex Rivera'}]});
 from.mockImplementation(table=>({select:()=>table==='field_crews'?{eq}:{in:memberIn}}));
 const res=response();
 await getCleanupTaskById({params:{id:'task'},query:{},user:{id:'staff'}},res,e=>{throw e});
 expect(eq).toHaveBeenCalledWith('id','team');
 expect(memberIn).toHaveBeenCalledWith('id',['member']);
 expect(res.body.assigned_team.name).toBe('Crew Alpha');
 expect(res.body.assigned_members[0].full_name).toBe('Alex Rivera');
});

test('summary detail never queries private crew profiles',async()=>{
 const res=response();
 await getCleanupTaskById({params:{id:'task'},query:{},user:{id:'citizen'}},res,e=>{throw e});
 expect(from).not.toHaveBeenCalled();
 expect(res.body).not.toHaveProperty('assigned_members');
});
test.each([{limit:'501'},{limit:'0'},{page:'-1'},{page:'NaN'},{limit:'2.5'}])('invalid list bounds fail before privileged read: %p',async(query)=>{
 const res=response();await getAllCleanupTasks({query,user:{id:'staff'}},res,e=>{throw e});expect(res.code).toBe(400);expect(rpc).not.toHaveBeenCalled();expect(from).not.toHaveBeenCalled();
});
test('database failure fails closed and never falls back to service table read',async()=>{
 const error={message:'Synthetic database unavailable'};rpc.mockResolvedValue({data:null,error});const next=jest.fn();
 await getTasksByClusterId({params:{clusterId:'cluster'},query:{},user:{id:'citizen'}},response(),next);expect(next).toHaveBeenCalledWith(error);expect(from).not.toHaveBeenCalled();
});
