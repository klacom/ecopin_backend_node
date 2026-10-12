import {jest} from '@jest/globals';
const from=jest.fn(),rpc=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{from,rpc}}));
jest.unstable_mockModule('../src/config/index.js',()=>({CLEANUP_TASK_PHOTOS_STORAGE_PATH:'Cleanup Task Photos',BEFORE_AFTER_PHOTO_FILE_SIZE:1024}));
jest.unstable_mockModule('../src/services/photo_dedup.service.js',()=>({hashBuffer:jest.fn(),checkPhotoDuplicate:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/dispatchPlanner.service.js',()=>({generateDispatchPlan:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/dispatchCommit.service.js',()=>({commitAndRoutePlan:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/taskFeedback.service.js',()=>({processTaskFeedback:jest.fn()}));
const {createCustomCleanupTask}=await import('../src/controllers/cleanup_task.controller.js');
const request=()=>({user:{id:'verified-desk'},body:{report_ids:['selected-report'],title:'Cleanup fixture',assigned_crew_ids:['selected-crew']}});
const response=()=>({code:200,status(code){this.code=code;return this;},json(body){this.body=body;return this;}});
beforeEach(()=>{from.mockReset();rpc.mockReset();from.mockImplementation(()=>{throw Error('Notification must be part of the database transaction');});});
test('manual task success relies on transactional notifications and never performs a second write',async()=>{
 rpc.mockResolvedValue({data:{status:'created',task:{id:'created-task',title:'Cleanup fixture'}},error:null});
 const res=response(),next=jest.fn();await createCustomCleanupTask(request(),res,next);
 expect(next).not.toHaveBeenCalled();expect(res.code).toBe(201);
 expect(from).not.toHaveBeenCalled();expect(rpc).toHaveBeenCalledWith('create_manual_cleanup_task',expect.objectContaining({actor:'verified-desk',crew_member_ids:['selected-crew']}));
});
test('conflicting manual claims do not send assignment notifications',async()=>{
 rpc.mockResolvedValue({data:{status:'conflict',reason:'stale_or_blocked_report'},error:null});
 const res=response();await createCustomCleanupTask(request(),res,jest.fn());expect(res.code).toBe(409);expect(from).not.toHaveBeenCalled();
});
test('atomic task/notification failure is returned without a second notification attempt',async()=>{
 const error={code:'P0001',message:'Synthetic transaction failure'};rpc.mockResolvedValue({data:null,error});
 const next=jest.fn();await createCustomCleanupTask(request(),response(),next);expect(next).toHaveBeenCalledWith(error);expect(from).not.toHaveBeenCalled();
});
