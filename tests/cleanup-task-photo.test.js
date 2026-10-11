import {jest} from '@jest/globals';
const rpc=jest.fn(),upload=jest.fn(),remove=jest.fn(),checkPhotoDuplicate=jest.fn();
let task;
const from=jest.fn(()=>({select:()=>({eq:()=>({single:async()=>({data:task,error:null})})})}));
const storageFrom=jest.fn(()=>({upload,remove,getPublicUrl:()=>({data:{publicUrl:'https://synthetic.invalid/photo'}})}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{from,rpc,storage:{from:storageFrom}}}));
jest.unstable_mockModule('../src/config/index.js',()=>({CLEANUP_TASK_PHOTOS_STORAGE_PATH:'Cleanup Task Photos',BEFORE_AFTER_PHOTO_FILE_SIZE:1024}));
jest.unstable_mockModule('../src/services/photo_dedup.service.js',()=>({hashBuffer:()=> 'synthetic-hash',checkPhotoDuplicate}));
jest.unstable_mockModule('../src/modules/optimization/services/dispatchPlanner.service.js',()=>({generateDispatchPlan:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/dispatchCommit.service.js',()=>({commitAndRoutePlan:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/taskFeedback.service.js',()=>({processTaskFeedback:jest.fn()}));
const {uploadCleanupPhoto,deleteCleanupPhoto}=await import('../src/controllers/cleanup_task.controller.js');
function response(){return {code:200,status(code){this.code=code;return this;},json(body){this.body=body;return this;}};}
async function run(actor='assigned',handler=uploadCleanupPhoto){const res=response();let failure;await handler({params:{taskId:'task'},body:{photo_type:'before'},user:{id:actor,role:'field_crew'},file:{buffer:Buffer.from('synthetic-image'),mimetype:'image/png'}},res,error=>{failure=error;});return {res,failure};}
beforeEach(()=>{task={id:'task',status:'pending',route_status:'ready',assigned_crew_ids:['assigned'],fc_version:4};rpc.mockReset();upload.mockReset();remove.mockReset();from.mockClear();storageFrom.mockClear();checkPhotoDuplicate.mockReset();checkPhotoDuplicate.mockResolvedValue({isDuplicate:false});upload.mockResolvedValue({error:null});remove.mockResolvedValue({error:null});rpc.mockResolvedValue({data:{status:'success',server_record:{id:'task',fc_version:5}},error:null});});
test('assigned crew uploads into the task and slot path and returns authoritative version',async()=>{const {res,failure}=await run();expect(failure).toBeUndefined();expect(res.body.task.fc_version).toBe(5);expect(storageFrom).toHaveBeenCalledWith('Cleanup Task Photos');expect(upload).toHaveBeenCalledWith(expect.stringMatching(/^task\/before\/[0-9a-f-]+$/),expect.any(Buffer),{contentType:'image/png',upsert:false});expect(rpc).toHaveBeenCalledWith('set_task_photo',expect.objectContaining({task_id:'task',actor:'assigned',slot:'before',expected_version:4}));});
test.each(['foreign','revoked'])('unassigned or reassigned crew %s is rejected before storage',async actor=>{const {failure}=await run(actor);expect(failure.statusCode).toBe(403);expect(upload).not.toHaveBeenCalled();expect(rpc).not.toHaveBeenCalled();});
test('unready route is rejected before storage',async()=>{task.route_status='needs_replan';const {failure}=await run();expect(failure.statusCode).toBe(403);expect(upload).not.toHaveBeenCalled();});
test.each(['completed','cancelled'])('inactive task %s is rejected before storage',async status=>{task.status=status;const {failure}=await run();expect(failure.statusCode).toBe(409);expect(upload).not.toHaveBeenCalled();expect(rpc).not.toHaveBeenCalled();});
test('assignment revoked during upload removes only the newly uploaded object',async()=>{rpc.mockResolvedValue({data:null,error:{code:'42501',message:'Task access denied'}});const {res,failure}=await run();expect(failure).toBeUndefined();expect(res.code).toBe(403);expect(remove).toHaveBeenCalledWith([upload.mock.calls[0][0]]);});
test('version conflict removes the new object and returns conflict',async()=>{rpc.mockResolvedValue({data:{status:'conflict',server_record:{fc_version:5}},error:null});const {res}=await run();expect(res.code).toBe(409);expect(remove).toHaveBeenCalledWith([upload.mock.calls[0][0]]);});
test('storage failure does not attempt authoritative attachment',async()=>{const error=new Error('synthetic storage unavailable');upload.mockResolvedValue({error});const {failure}=await run();expect(failure).toBe(error);expect(rpc).not.toHaveBeenCalled();});
test('duplicate content does not allocate another storage object',async()=>{checkPhotoDuplicate.mockResolvedValue({isDuplicate:true});const {res}=await run();expect(res.body.duplicate).toBe(true);expect(upload).not.toHaveBeenCalled();expect(rpc).not.toHaveBeenCalled();});
test('unassigned crew cannot clear an attached task photo',async()=>{const {failure}=await run('foreign',deleteCleanupPhoto);expect(failure.statusCode).toBe(403);expect(rpc).not.toHaveBeenCalled();});
