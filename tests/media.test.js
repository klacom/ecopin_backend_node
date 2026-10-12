import {jest} from '@jest/globals';
const download=jest.fn(),storageFrom=jest.fn(()=>({download})),createClient=jest.fn(()=>({storage:{from:storageFrom}}));
jest.unstable_mockModule('@supabase/supabase-js',()=>({createClient}));
jest.unstable_mockModule('../src/config/index.js',()=>({NEXT_PUBLIC_SUPABASE_URL:'https://project.test',SUPABASE_ANON_KEY:'publishable',SUPABASE_SERVICE_ROLE_KEY:'must-never-be-used'}));
const {getStorageMedia}=await import('../src/controllers/media.controller.js');
const response=()=>({code:200,headers:{},status(code){this.code=code;return this},json(value){this.value=value;return this},set(name,value){this.headers[name]=value;return this},send(value){this.value=value;return this}});
const request=()=>({query:{bucket:'Cleanup Task Photos',path:'task/before/photo.jpg'},headers:{authorization:'Bearer user-jwt'}});
beforeEach(()=>{download.mockReset();createClient.mockClear();download.mockResolvedValue({data:new Blob(['image'],{type:'image/png'}),error:null})});
test('authorized bytes use caller identity without exposing bearer links',async()=>{
 const res=response();await getStorageMedia(request(),res,error=>{throw error});
 expect(createClient).toHaveBeenCalledWith('https://project.test','publishable',expect.objectContaining({global:{headers:{Authorization:'Bearer user-jwt'}}}));
 expect(res.value.equals(Buffer.from('image'))).toBe(true);expect(res.headers['Cache-Control']).toBe('private, no-store');
});
test('Storage denial never falls back to public or signed URLs',async()=>{
 download.mockResolvedValue({data:null,error:{statusCode:403}});const res=response();await getStorageMedia(request(),res,error=>{throw error});expect(res.code).toBe(404);
});
test('anonymous and malformed paths are rejected before Storage',async()=>{
 const req=request();req.headers={};const res=response();await getStorageMedia(req,res);expect(res.code).toBe(401);expect(createClient).not.toHaveBeenCalled();
 req.query.path='../../secret';await getStorageMedia(req,res);expect(res.code).toBe(400);expect(createClient).not.toHaveBeenCalled();
});
