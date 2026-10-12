import {jest} from '@jest/globals';
import {createHash} from 'node:crypto';
const rpc=jest.fn(),from=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc,from}}));
jest.unstable_mockModule('../src/config/email.config.js',()=>({transporter:{sendMail:jest.fn()}}));
jest.unstable_mockModule('../src/config/index.js',()=>({SMTP_FROM_NAME:'Synthetic',SMTP_USER:'sender@example.invalid',APP_BASE_URL:'http://localhost:4002',EMAIL_VERIFICATION_EXPIRY_HOURS:24}));
const {generateVerificationToken}=await import('../src/services/email.service.js');
beforeEach(()=>{rpc.mockReset();from.mockReset();from.mockReturnValue({insert:async()=>({error:null})});rpc.mockResolvedValue({data:'synthetic-issuance',error:null});});
test('issuance sends only a SHA256 digest to database and retains the delivered UUID format',async()=>{
 const token=await generateVerificationToken('synthetic-user');
 expect(token).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
 expect(rpc).toHaveBeenCalledWith('issue_email_verification',{
  p_user_id:'synthetic-user',p_token_digest:createHash('sha256').update(token).digest('hex'),p_ttl_hours:24
 });
 expect(JSON.stringify(rpc.mock.calls)).not.toContain(token);
 expect(from).not.toHaveBeenCalled();
});
test('distributed issuance deferral returns no token to send',async()=>{
 rpc.mockResolvedValue({data:null,error:null});
 expect(await generateVerificationToken('synthetic-user')).toBeNull();
});
test('issuance with email passes normalized email to issue_email_verification RPC', async () => {
 const token = await generateVerificationToken('synthetic-user', '  Alice@Example.COM  ');
 expect(token).toBeDefined();
 expect(rpc).toHaveBeenCalledWith('issue_email_verification', {
  p_user_id: 'synthetic-user',
  p_token_digest: createHash('sha256').update(token).digest('hex'),
  p_ttl_hours: 24,
  p_email: 'alice@example.com'
 });
});
test('issuance falls back to 3-parameter overload if database has unmigrated schema (PGRST202)', async () => {
 rpc.mockImplementation(async (name, args) => {
  if (args.p_email) return { data: null, error: { code: 'PGRST202', message: 'Could not find function with parameter p_email' } };
  return { data: 'legacy-issuance', error: null };
 });
 const token = await generateVerificationToken('synthetic-user', 'alice@example.com');
 expect(token).toBeDefined();
 expect(rpc).toHaveBeenCalledTimes(2);
 expect(rpc).toHaveBeenLastCalledWith('issue_email_verification', {
  p_user_id: 'synthetic-user',
  p_token_digest: createHash('sha256').update(token).digest('hex'),
  p_ttl_hours: 24
 });
});
test('database issuance errors propagate a safe message without echoing digest details',async()=>{
 const errorLog=jest.spyOn(console,'error').mockImplementation(()=>{});
 let digest;
 from.mockReturnValue({insert:async value=>{digest=value.token;return {error:{code:'23505',details:digest}}}});
 rpc.mockImplementation(async(_,args)=>{digest=args.p_token_digest;return {data:null,error:{code:'23505',details:digest}}});
 try{
  await expect(generateVerificationToken('synthetic-user')).rejects.toThrow(/^Failed to generate verification token$/);
  expect(JSON.stringify(errorLog.mock.calls)).not.toContain(digest);
 }finally{errorLog.mockRestore();}
});
