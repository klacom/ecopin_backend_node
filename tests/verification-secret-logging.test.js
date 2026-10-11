import {jest} from '@jest/globals';
let storedToken;
const sendMail=jest.fn(),insert=jest.fn();
const supabaseAdmin={
 rpc:jest.fn(async()=>({data:'synthetic-issuance',error:null})),
 from:jest.fn(()=>({upsert:async()=>({error:null}),insert:async(value)=>{if(value.token)storedToken=value.token;insert(value);return {error:null}}})),
 auth:{admin:{createUser:async()=>({data:{user:{id:'synthetic-user',email:'citizen@example.invalid'}},error:null}),listUsers:jest.fn()}}
};
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin,supabase:{}}));
jest.unstable_mockModule('../src/config/email.config.js',()=>({transporter:{sendMail}}));
jest.unstable_mockModule('../src/config/index.js',()=>({SMTP_FROM_NAME:'Synthetic',SMTP_USER:'noreply@example.invalid',APP_BASE_URL:'http://localhost:4002',EMAIL_VERIFICATION_EXPIRY_HOURS:24,MOBILE_REDIRECT_URL:'ecopin://auth'}));
const {sendVerificationEmail,generateVerificationToken}=await import('../src/services/email.service.js');
const {register,resendVerification}=await import('../src/controllers/auth.controller.js');
let log,errorLog;
beforeEach(()=>{sendMail.mockReset();sendMail.mockResolvedValue({messageId:'synthetic-message'});insert.mockClear();supabaseAdmin.from.mockReset();supabaseAdmin.from.mockImplementation(()=>({upsert:async()=>({error:null}),insert:async value=>{insert(value);return {error:null}}}));supabaseAdmin.rpc.mockReset();supabaseAdmin.rpc.mockResolvedValue({data:'synthetic-issuance',error:null});storedToken=null;log=jest.spyOn(console,'log').mockImplementation(()=>{});errorLog=jest.spyOn(console,'error').mockImplementation(()=>{});});
afterEach(()=>{log.mockRestore();errorLog.mockRestore();});
function output(){return JSON.stringify([...log.mock.calls,...errorLog.mock.calls]);}
test('email contains its verification link while runtime logs exclude the secret',async()=>{
 const token='synthetic-secret-token-for-test';
 await sendVerificationEmail('citizen@example.invalid',token);
 expect(sendMail).toHaveBeenCalledWith(expect.objectContaining({text:expect.stringContaining('token='+token)}));
 expect(output()).not.toContain(token);
});
test('registration logs neither the generated token nor its prefix',async()=>{
 const res={status(){return this},json(value){this.body=value;return this}};
 await register({body:{email:'citizen@example.invalid',password:'SyntheticPassword123!'},ip:'127.0.0.1',get:()=> 'synthetic-agent'},res,e=>{throw e});
 storedToken=sendMail.mock.calls[0]?.[0].text.match(/token=([0-9a-f-]+)/)?.[1];
 expect(storedToken).toBeTruthy();expect(res.body.message).toContain('Registration successful');
 expect(output()).not.toContain(storedToken);expect(output()).not.toContain(storedToken.slice(0,10));
});
test('database failure details cannot echo the token digest into logs',async()=>{
 let failedToken;
 supabaseAdmin.rpc.mockImplementationOnce(async(_,value)=>{failedToken=value.p_token_digest;return {data:null,error:{code:'23503',details:'Failing row contains '+failedToken}}});
 await expect(generateVerificationToken('synthetic-user')).rejects.toThrow('Failed to generate verification token');
 expect(failedToken).toBeTruthy();expect(output()).not.toContain(failedToken);
});
test('SMTP failure does not echo a verification URL into logs or the propagated error',async()=>{
 const secret='synthetic-smtp-secret';
 sendMail.mockRejectedValue({code:'EMESSAGE',message:'Failed token='+secret,details:'Private message contents'});
 await expect(sendVerificationEmail('citizen@example.invalid',secret)).rejects.toThrow(/^Failed to send verification email via SMTP$/);
 expect(output()).not.toContain(secret);
});

test('deferred registration issuance does not send a null verification link',async()=>{
 supabaseAdmin.rpc.mockResolvedValue({data:null,error:null});
 const res={status(){return this},json(value){this.body=value;return this}};
 await register({body:{email:'citizen@example.invalid',password:'SyntheticPassword123!'},ip:'127.0.0.1',get:()=> 'synthetic-agent'},res,e=>{throw e});
 expect(sendMail).not.toHaveBeenCalled();
 expect(res.body.message).toContain('Registration successful');
});

test.each(['absent','verified','deferred','issued','issuance_error','smtp_error','auth_error'])('resend gives the same response for %s account and never sends deferred links',async state=>{
 supabaseAdmin.auth.admin.listUsers.mockResolvedValue({data:{users:state==='absent'?[]:[{id:'synthetic-user',email:'citizen@example.invalid'}]},error:null});
 supabaseAdmin.from.mockReturnValueOnce({select:()=>({eq:()=>({single:async()=>({data:{is_email_verified:state==='verified'},error:null})})})});
 supabaseAdmin.rpc.mockResolvedValue({data:state==='deferred'?null:'synthetic-issuance',error:null});
 if(state==='issuance_error')supabaseAdmin.rpc.mockResolvedValue({data:null,error:{code:'23503'}});
 if(state==='smtp_error')sendMail.mockRejectedValue(new Error('Synthetic SMTP unavailable'));
 if(state==='auth_error')supabaseAdmin.auth.admin.listUsers.mockResolvedValue({data:{users:[]},error:{message:'Synthetic Auth unavailable'}});
 const res={code:null,status(code){this.code=code;return this},json(value){this.body=value;return this}};
 await resendVerification({body:{email:'citizen@example.invalid'}},res,e=>{throw e});
 expect(res.code).toBe(200);expect(res.body.message).toBe('If an account exists, a verification email has been sent.');
 if(['issued','smtp_error'].includes(state))expect(sendMail).toHaveBeenCalledTimes(1);else expect(sendMail).not.toHaveBeenCalled();
});
