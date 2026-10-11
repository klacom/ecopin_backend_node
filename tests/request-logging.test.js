import {jest} from '@jest/globals';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {redactRequestUrl,requestLogger} from '../src/middleware/requestLogging.middleware.js';
test.each([
 ['/api/auth/verify-email?token=secret&limit=20','secret'],
 ['/callback?%74oken=secret&token=second-secret','second-secret'],
 ['/callback?access_token=secret&refresh_token=second-secret','secret'],
 ['/callback?CoDe=secret','secret'],
 ['/auth?password=secret','secret'],
 ['https://username:secret@synthetic.invalid/auth?token=another-secret','secret'],
])('sensitive URL query or credentials are not logged: %s',(url,secret)=>{
 const safe=redactRequestUrl(url);expect(safe).not.toContain(secret);expect(safe).toContain('REDACTED');
});
test('ordinary query filters remain available for diagnostics',()=>{
 expect(redactRequestUrl('/api/reports/public?limit=25&page=2')).toBe('/api/reports/public?limit=25&page=2');
});
test('missing URL is a safe placeholder',()=>{expect(redactRequestUrl(undefined)).toBe('-')});
test('actual HTTP middleware redacts URL and referrer while retaining response diagnostics',async()=>{
 const write=jest.fn();const logger=requestLogger({stream:{write}});
 const server=createServer((req,res)=>logger(req,res,()=>{res.end('ok')}));
 try{
  server.listen(0,'127.0.0.1');await once(server,'listening');
  const response=await fetch('http://127.0.0.1:'+server.address().port+'/api/auth/verify-email?token=synthetic-secret&limit=2',{headers:{Referer:'https://synthetic.invalid/auth?token=referrer-secret'}});
  await response.text();await new Promise(resolve=>setImmediate(resolve));
  const output=write.mock.calls.map(args=>args[0]).join('');
  expect(output).toContain('GET /api/auth/verify-email');expect(output).toContain('200');expect(output).toContain('limit=2');
  expect(output).not.toContain('synthetic-secret');expect(output).not.toContain('referrer-secret');
 }finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve))}
});
