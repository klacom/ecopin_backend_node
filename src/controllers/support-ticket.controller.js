import {supabaseAdmin as db} from '../config/supabase.config.js';

export const TICKET_CATEGORIES=['status_inquiry','location_mismatch','re_inspection','hazard_escalation','account_help','other'];
const TICKET_STATUSES=['open','in_progress','resolved','closed'];
const REPLY_STATUSES=['in_progress','resolved','closed'];
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REFERENCE=/^TCK-\d{6,12}$/i;
const unavailable='Support tickets are unavailable. Please try again.';

const sendError=(res,error,fallback=unavailable)=>{
 const map={'42501':[403,'You do not have access to this ticket desk.'],P0002:[404,'Ticket or report not found.'],
  '53400':[429,'You already have 5 open tickets. Wait for a reply before opening another.'],'22023':[400,'Check the ticket details and try again.'],
  '23514':[400,'Check the ticket details and try again.']};
 const [status,message]=map[error?.code]||[503,fallback];
 return res.status(status).json({error:message});
};
const call=(name,args)=>db.rpc(name,args).abortSignal(AbortSignal.timeout(6000));
const cursorFrom=query=>{
 const {before_created=null,before_id=null}=query||{};
 if((before_created===null)!==(before_id===null))return {invalid:true};
 if(before_created===null)return {created:null,id:null};
 if(typeof before_created!=='string'||typeof before_id!=='string'||!UUID.test(before_id)||!Number.isFinite(Date.parse(before_created)))return {invalid:true};
 return {created:before_created,id:before_id};
};
const limitFrom=(query,max)=>{
 const {limit='20'}=query||{};
 return typeof limit==='string'&&/^\d{1,3}$/.test(limit)&&Number(limit)>=1&&Number(limit)<=max?Number(limit):null;
};

// The actor is always the authenticated session; no client-supplied identity is read.
export async function createTicket(req,res){
 res.set('Cache-Control','private, no-store');
 const {category,description,report_id=null}=req.body||{};
 const text=typeof description==='string'?description.trim():'';
 if(!TICKET_CATEGORIES.includes(category)||text.length<10||text.length>2000||
  (report_id!==null&&(typeof report_id!=='string'||!UUID.test(report_id))))
  return res.status(400).json({error:'Choose a category, add a description of 10 to 2000 characters, and use a valid report ID if you include one.'});
 try{
  const {data,error}=await call('create_support_ticket',{actor:req.user.id,ticket_category:category,ticket_description:text,ticket_report_id:report_id});
  if(error||!data?.reference)return sendError(res,error,'Your ticket could not be saved. Please try again.');
  return res.status(201).json(data);
 }catch{return res.status(503).json({error:'Your ticket could not be saved. Please try again.'});}
}

export async function listMyTickets(req,res){
 res.set('Cache-Control','private, no-store');
 const cursor=cursorFrom(req.query),limit=limitFrom(req.query,50);
 if(cursor.invalid||limit===null)return res.status(400).json({error:'Choose a valid ticket page.'});
 try{
  const {data,error}=await call('read_my_support_tickets',{actor:req.user.id,cursor_created:cursor.created,cursor_id:cursor.id,page_limit:limit});
  if(error||!Array.isArray(data?.tickets))return sendError(res,error);
  return res.json(data);
 }catch{return res.status(503).json({error:unavailable});}
}

export async function getMyTicket(req,res){
 res.set('Cache-Control','private, no-store');
 const reference=req.params?.reference;
 if(typeof reference!=='string'||!REFERENCE.test(reference))return res.status(404).json({error:'Ticket or report not found.'});
 try{
  const {data,error}=await call('read_my_support_ticket',{actor:req.user.id,ticket_ref:reference});
  if(error||!data?.reference)return sendError(res,error);
  return res.json(data);
 }catch{return res.status(503).json({error:unavailable});}
}

export async function listTicketQueue(req,res){
 res.set('Cache-Control','private, no-store');
 const {status=null}=req.query||{};
 const cursor=cursorFrom(req.query),limit=limitFrom(req.query,100);
 if(cursor.invalid||limit===null||(status!==null&&!TICKET_STATUSES.includes(status)))return res.status(400).json({error:'Choose a valid ticket page.'});
 try{
  const {data,error}=await call('read_support_ticket_queue',{actor:req.user.id,status_filter:status,cursor_created:cursor.created,cursor_id:cursor.id,page_limit:limit});
  if(error||!Array.isArray(data?.tickets))return sendError(res,error);
  return res.json(data);
 }catch{return res.status(503).json({error:unavailable});}
}

export async function respondToTicket(req,res){
 res.set('Cache-Control','private, no-store');
 const {id}=req.params||{},{response,status}=req.body||{};
 const reply=typeof response==='string'?response.trim():'';
 if(typeof id!=='string'||!UUID.test(id)||!REPLY_STATUSES.includes(status)||reply.length<1||reply.length>2000)
  return res.status(400).json({error:'Add a reply of up to 2000 characters and choose in progress, resolved or closed.'});
 try{
  const {data,error}=await call('respond_support_ticket',{actor:req.user.id,ticket_id:id,reply,new_status:status});
  if(error||!data?.reference)return sendError(res,error,'Your reply could not be saved. Please try again.');
  return res.json(data);
 }catch{return res.status(503).json({error:'Your reply could not be saved. Please try again.'});}
}
