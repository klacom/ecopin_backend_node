// Identity of the running release. The CI build writes the commit SHA into a RELEASE file inside the immutable artifact; the process reads it once at start.
// /health publishes it so a deploy or an acceptance check can compare what is actually serving with what was selected. A health result that is "OK"
// says nothing about which release answered, which is how a stale or wrong release can look healthy.
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
const SHA=/^[0-9a-f]{40}$/;
export function readReleaseIdentity({root=process.cwd(),readFile=readFileSync,now=()=>new Date()}={}){
 const startedAt=now().toISOString();
 try{
  const sha=String(readFile(join(root,'RELEASE'),'utf8')).trim().toLowerCase();
  return SHA.test(sha)?{sha,source:'artifact',started_at:startedAt}:{sha:null,source:'invalid',started_at:startedAt};
 }catch{return {sha:null,source:'absent',started_at:startedAt};}
}
export const releaseIdentity=readReleaseIdentity();
