// Request budgets and safe failure categories for interactive reads.
// The web proxy aborts upstream requests after 10 s (lib/server/session-http.mjs, authorityFetch). A backend read must finish, or fail with a
// controlled error, before that, otherwise the browser sees a generic gateway failure while the database keeps working for nobody.
// Longer operations (for example plan commit, which the proxy budgets separately) must not use this helper.
export const WEB_PROXY_BUDGET_MS=10000;
export const INTERACTIVE_READ_BUDGET_MS=8000;
export const readBudget=()=>AbortSignal.timeout(INTERACTIVE_READ_BUDGET_MS);

// Internal category from a Supabase/PostgREST error or a thrown error. Only the category and the SQLSTATE-style code leave this module.
export function classifyFailure(error){
 const code=String(error?.code??''),text=String(error?.message??''),name=String(error?.name??'');
 if(code==='42501')return 'denied';
 if(code==='P0002'||code==='PGRST116')return 'not_found';
 if(['PGRST202','42883','42P01','42703','55000'].includes(code))return 'missing_prerequisite';
 if(['22023','22P02','23514'].includes(code))return 'invalid_request';
 if(code==='54000')return 'too_large';
 if(code==='57014'||name==='TimeoutError'||name==='AbortError'||/^(TimeoutError|AbortError)\b/.test(text))return 'timeout';
 return 'unavailable';
}
const STATUS={denied:403,not_found:404,missing_prerequisite:503,invalid_request:400,too_large:422,timeout:504,unavailable:503};
const RETRYABLE=new Set(['timeout','unavailable']);
const DEFAULT_TEXT={
 denied:'Access denied.',not_found:'Not found.',invalid_request:'Check the request and try again.',too_large:'The result is too large. Narrow the request and try again.',
 timeout:'The request took too long. Please retry.',missing_prerequisite:'This feature is not ready on the server. Required data migrations must be applied.',
 unavailable:'Temporarily unavailable. Please retry.',
};
// Writes a controlled JSON failure. `text` may override the wording per category. The log line carries the area, category and code only:
// never the message, the request, or any payload, because database errors can echo row values.
export function sendFailure(res,area,error,text={}){
 const category=classifyFailure(error),code=String(error?.code??'');
 console.warn('[request-failure]',{area,category,...( /^[A-Za-z0-9]{2,8}$/.test(code)?{code}:{})});
 return res.status(STATUS[category]).json({error:text[category]??DEFAULT_TEXT[category],code:category,retryable:RETRYABLE.has(category)});
}
