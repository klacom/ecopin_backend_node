import {mkdtempSync,writeFileSync,readFileSync,mkdirSync,rmSync,chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,delimiter} from 'node:path';
import {spawnSync} from 'node:child_process';
import {readReleaseIdentity} from '../src/services/release-identity.js';

const SHA='5fc531deda5fcb6678e5f870da3e405fecbc3819',OTHER='75f056735be0c8d07e73d114eb8f59601d1311fc';
const script=readFileSync(new URL('../scripts/deploy/deploy-backend.sh',import.meta.url),'utf8').replace(/\r\n/g,'\n');
const snippet=script.slice(script.indexOf("<<'NODE'\n")+9,script.indexOf('\nNODE\n'));

describe('RELEASE file',()=>{
 const at=files=>readReleaseIdentity({root:'/release',readFile:(path)=>{const name=path.replace(/\\/g,'/');if(!(name in files))throw new Error('ENOENT');return files[name];}});
 test('a valid SHA is the identity, normalised',()=>{expect(at({'/release/RELEASE':SHA.toUpperCase()+'\n'})).toMatchObject({sha:SHA,source:'artifact'});});
 test.each([['empty',''],['short','abc123'],['not hex','z'.repeat(40)],['two lines',SHA+'\n'+OTHER],['injection',SHA+'; rm -rf /']])('an invalid file (%s) gives no identity',(_,content)=>{
  expect(at({'/release/RELEASE':content})).toMatchObject({sha:null,source:'invalid'});
 });
 test('a missing file is reported as absent, never guessed',()=>{expect(at({})).toMatchObject({sha:null,source:'absent'});});
 test('the start time is recorded',()=>{expect(readReleaseIdentity({root:'/x',readFile:()=>{throw new Error('x');},now:()=>new Date('2026-11-03T00:00:00Z')}).started_at).toBe('2026-11-03T00:00:00.000Z');});
});

describe('deploy script identity comparison (the real snippet, with a stand-in process list)',()=>{
 let dir;
 beforeEach(()=>{dir=mkdtempSync(join(tmpdir(),'t14b-'));mkdirSync(join(dir,'bin'));mkdirSync(join(dir,'rel'));});
 afterEach(()=>rmSync(dir,{recursive:true,force:true}));
 function run({health,processes,releaseFile}){
  const rel=join(dir,'rel');if(releaseFile!==undefined)writeFileSync(join(rel,'RELEASE'),releaseFile);
  writeFileSync(join(dir,'health.json'),typeof health==='string'?health:JSON.stringify(health));
  writeFileSync(join(dir,'jlist.json'),JSON.stringify(processes(rel)));
  const win=process.platform==='win32';
  const stub=join(dir,'bin',win?'pm2.cmd':'pm2');
  writeFileSync(stub,win?`@echo off\r\ntype "${join(dir,'jlist.json')}"\r\n`:`#!/bin/sh\ncat "${join(dir,'jlist.json')}"\n`);if(!win)chmodSync(stub,0o755);
  writeFileSync(join(dir,'check.cjs'),snippet);
  const r=spawnSync(process.execPath,[join(dir,'check.cjs'),SHA,rel,join(dir,'health.json')],{encoding:'utf8',env:{...process.env,PATH:join(dir,'bin')+delimiter+process.env.PATH}});
  return {code:r.status,out:r.stdout+r.stderr};
 }
 const online=cwd=>[{name:'backend',pm2_env:{status:'online',pm_cwd:cwd}}];
 test('selected release, health, process directory and RELEASE file agree: accepted',()=>{
  const r=run({health:{release:{sha:SHA,source:'artifact'}},processes:online,releaseFile:SHA+'\n'});expect(r.code).toBe(0);expect(r.out).toContain('Release identity verified');
 });
 test('a green health from a DIFFERENT release fails',()=>{
  const r=run({health:{status:'OK',release:{sha:OTHER,source:'artifact'}},processes:online,releaseFile:SHA+'\n'});expect(r.code).not.toBe(0);expect(r.out).toContain(`health reports release ${OTHER}`);
 });
 test('a green health that names no release fails when the artifact carries a RELEASE file',()=>{
  const r=run({health:{status:'OK'},processes:online,releaseFile:SHA+'\n'});expect(r.code).not.toBe(0);expect(r.out).toMatch(/health reports release none/);
 });
 test('a legacy artifact without RELEASE is accepted on directory and process alone',()=>{
  const r=run({health:{status:'OK'},processes:online});expect(r.code).toBe(0);expect(r.out).toContain('Legacy artifact');
 });
 test('the right health but a process running from another directory fails',()=>{
  const r=run({health:{release:{sha:SHA}},processes:()=>online('/home/ubuntu/ecopin_backend_node'),releaseFile:SHA});expect(r.code).not.toBe(0);expect(r.out).toContain('the process runs from');
 });
 test.each([['stopped',[{name:'backend',pm2_env:{status:'stopped',pm_cwd:'x'}}]],['absent',[{name:'other',pm2_env:{status:'online',pm_cwd:'x'}}]]])('a backend process that is %s fails',(_,list)=>{
  const r=run({health:{release:{sha:SHA}},processes:()=>list,releaseFile:SHA});expect(r.code).not.toBe(0);expect(r.out).toMatch(/not online/);
 });
 test('a health response that is not JSON fails',()=>{
  const r=run({health:'<html>502</html>',processes:online,releaseFile:SHA});expect(r.code).not.toBe(0);expect(r.out).toContain('not JSON');
 });
 test('the script runs the comparison before pointing current at the release and verifies current afterwards',()=>{
  const body=script.slice(script.indexOf('trap rollback ERR\nstart_release'));
  expect(body.indexOf('healthy')).toBeLessThan(body.indexOf('identity_ok'));
  expect(body.indexOf('identity_ok')).toBeLessThan(body.indexOf('ln -sfn "$target" "$root/current"'));
  expect(body).toMatch(/readlink -f "\$root\/current"/);
 });
});
