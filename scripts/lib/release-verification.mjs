// Role-aware release verification: which release is answering, and is every recovered feature actually registered and reachable for the roles that need it.
//
// Why role-aware: most routers sit behind shared authentication middleware, so an unauthenticated probe gets 401 whether or not the handler behind it
// exists, and a green /health says nothing about handlers. A probe made with a real session for the authorised role reaches the router; a handler that is
// missing falls through to the backend's 404 handler, which answers `{error:'Route not found', code:'route_not_found'}`. That answer, and only that
// answer, means "not registered". Denied probes with an unauthorised role must be 403: 404 means the route is missing, 200 means access leaked.

export const ROLES=['officer','admin','citizen','field_crew'];
const ZERO='00000000-0000-4000-8000-000000000000';
const month=today=>{const d=new Date(today+'T00:00:00Z');d.setUTCMonth(d.getUTCMonth()-1);return d.toISOString().slice(0,7);};

// feature: the recovered capability (T-number); role: the session used; allow: statuses that count as accepted in strict mode.
// `registered` statuses (strict=false) only require that the route is not reported missing and the role gate answered as expected.
export function buildManifest({today}){
 const m=month(today),probe=(feature,role,path,allow,extra={})=>({id:`${feature.split(' ')[0]} ${role} ${path.split('?')[0]}`,feature,role,method:'GET',path,allow,...extra});
 const deny=(feature,role,path)=>({...probe(feature,role,path,[403]),denied:true});
 return [
  probe('T04 executive report','officer',`/api/analytics/barangay/executive?month=${m}`,[200]),
  probe('T04 executive report','admin',`/api/analytics/barangay/executive?month=${m}`,[200]),
  deny('T04 executive report','citizen',`/api/analytics/barangay/executive?month=${m}`),
  probe('T04 barangay analytics','officer',`/api/analytics/barangay?startMonth=${m}&endMonth=${m}`,[200]),
  probe('T05 operational history','officer','/api/operational-events?limit=1',[200]),
  probe('T05 live operations feed','officer','/api/operational-events/live?limit=1',[200]),
  deny('T05 operational history','citizen','/api/operational-events?limit=1'),
  deny('T05 live operations feed','field_crew','/api/operational-events/live?limit=1'),
  probe('T06 citizen support tickets','citizen','/api/support/tickets?limit=1',[200]),
  probe('T06 staff support queue','officer','/api/support/queue?limit=1',[200]),
  deny('T06 staff support queue','citizen','/api/support/queue?limit=1'),
  deny('T06 citizen support tickets','officer','/api/support/tickets?limit=1'),
  // A malformed request proves the route and its validation without calling the routing provider.
  probe('T07 field directions','field_crew','/api/routing/directions?from=bad&to=bad',[400]),
  deny('T07 field directions','citizen','/api/routing/directions?from=bad&to=bad'),
  probe('T08 incident case record','officer',`/api/reports/${ZERO}/case-record`,[404]),
  deny('T08 incident case record','citizen',`/api/reports/${ZERO}/case-record`),
  probe('T09 cleanup proof review','officer',`/api/reports/${ZERO}/cleanup-proof`,[200,404]),
  deny('T09 cleanup proof review','citizen',`/api/reports/${ZERO}/cleanup-proof`),
  probe('T09 public cleanup proof','anonymous',`/api/reports/${ZERO}/cleanup-proof/public`,[200]),
  probe('T10 crew operations summary','officer',`/api/sweeper/operations-summary?from=${today}`,[200]),
  deny('T10 crew operations summary','citizen',`/api/sweeper/operations-summary?from=${today}`),
  probe('T11 unprocessed incident alerts','officer','/api/reports/unprocessed-alerts?limit=1',[200]),
 ];
}
export const FEATURES=today=>[...new Set(buildManifest({today}).map(p=>p.feature.split(' ')[0]))];

export const isMissingRoute=(status,body)=>status===404&&(body?.code==='route_not_found'||body?.error==='Route not found');

async function call(fetchImpl,base,token,probe){
 const headers={Accept:'application/json',...(token?{Authorization:`Bearer ${token}`}:{})};
 const response=await fetchImpl(base+probe.path,{method:probe.method,headers,signal:AbortSignal.timeout(15000)});
 let body=null;try{body=await response.json();}catch{/* non-JSON answers are judged by status alone */}
 return {status:response.status,body};
}

export async function verifyRelease({base,fetchImpl=fetch,tokens={},expectSha=null,skipIdentity=false,requireClassifier=true,strict=true,requireEscalation=false,today=new Date().toISOString().slice(0,10)}){
 const results=[],add=(entry)=>results.push(entry);
 const url=base.replace(/\/$/,'');
 // 1. Identity: what answers must be the release that was selected. Health alone is never enough.
 let health=null;
 try{const r=await fetchImpl(url+'/health',{signal:AbortSignal.timeout(20000)});health=await r.json();}catch(error){add({id:'health',feature:'release identity',outcome:'error',detail:`health unreachable: ${error?.message??error}`});}
 if(health){
  const dependencies=health.dependencies??{};
  add({id:'health database',feature:'release identity',outcome:dependencies.database==='available'?'pass':'unexpected_status',detail:`database ${dependencies.database??'unreported'}`});
  const classifierOk=['available','warming'].includes(dependencies.classifier);
  add({id:'health classifier',feature:'T13 classifier',outcome:classifierOk?'pass':requireClassifier?'unexpected_status':'skipped',detail:`classifier ${dependencies.classifier??'unreported'} (warming counts as reachable)${!classifierOk&&!requireClassifier?'; not required on this stack':''}`});
  if(skipIdentity)add({id:'release identity',feature:'release identity',outcome:'skipped',detail:'explicitly skipped by the caller'});
  else if(!expectSha)add({id:'release identity',feature:'release identity',outcome:'error',detail:'no expected release SHA was supplied'});
  else if(!health.release?.sha)add({id:'release identity',feature:'release identity',outcome:'release_unreported',detail:`the running process reports no release (${health.release?.source??'no release field'})`});
  else add({id:'release identity',feature:'release identity',outcome:health.release.sha===expectSha?'pass':'release_mismatch',detail:`running ${health.release.sha}, expected ${expectSha}`});
  if(requireEscalation){const j=health.jobs?.unprocessed_escalation;add({id:'T11 escalation job',feature:'T11 unprocessed incident alerts',outcome:j?.enabled===true?'pass':'unexpected_status',detail:j?`registered=${j.enabled}, last outcome ${j.last_outcome??'none yet'}`:'job state absent from health'});}
 }
 // 2. Features, with a real session for each role.
 for(const probe of buildManifest({today})){
  const token=probe.role==='anonymous'?null:tokens[probe.role];
  if(probe.role!=='anonymous'&&!token){add({id:probe.id,feature:probe.feature,role:probe.role,outcome:'no_credentials',detail:`no ${probe.role} session was supplied, so this feature cannot be verified`});continue;}
  try{
   const {status,body}=await call(fetchImpl,url,token,probe);
   if(isMissingRoute(status,body))add({id:probe.id,feature:probe.feature,role:probe.role,status,outcome:'missing_route',detail:'the backend answered route_not_found: this release does not register the route'});
   else if(probe.denied)add({id:probe.id,feature:probe.feature,role:probe.role,status,outcome:status===403?'pass':status===200?'access_leak':'unexpected_status',detail:`${probe.role} must be refused with 403, got ${status}`});
   else if(probe.allow.includes(status))add({id:probe.id,feature:probe.feature,role:probe.role,status,outcome:'pass',detail:`HTTP ${status}`});
   else add({id:probe.id,feature:probe.feature,role:probe.role,status,outcome:strict?'unexpected_status':'pass',detail:`HTTP ${status}${body?.code?` (${body.code})`:''}; expected ${probe.allow.join(' or ')}${strict?'':' (registered; strict acceptance not required in this mode)'}`});
  }catch(error){add({id:probe.id,feature:probe.feature,role:probe.role,outcome:'error',detail:String(error?.message??error).slice(0,120)});}
 }
 const failed=results.filter(r=>!['pass','skipped'].includes(r.outcome));
 return {ok:failed.length===0,total:results.length,passed:results.filter(r=>r.outcome==='pass').length,failed,results};
}

export function formatReport(report){
 const lines=[`Release verification: ${report.ok?'PASSED':'FAILED'} (${report.passed}/${report.total} passed${report.results.some(r=>r.outcome==='skipped')?', identity skipped':''})`];
 for(const r of report.results){if(r.outcome==='pass')continue;lines.push(`  ${r.outcome.toUpperCase().padEnd(17)} ${r.feature}${r.role?` [${r.role}]`:''}: ${r.detail}`);}
 return lines.join('\n');
}
