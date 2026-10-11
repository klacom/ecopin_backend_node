import morgan from 'morgan';

const combined=morgan.compile(':remote-addr - :remote-user [:date[clf]] ":method :url HTTP/:http-version" :status :res[content-length] ":referrer" ":user-agent"');
const sensitiveParameter=/(token|password|secret|authorization|^code$|^key$|^api_key$)/i;

export function redactRequestUrl(value) {
  if (!value) return '-';
  try {
    const url=new URL(value,'http://request.invalid');
    for (const key of new Set(url.searchParams.keys())) {
      if (sensitiveParameter.test(key)) url.searchParams.set(key,'[REDACTED]');
    }
    const origin=/^https?:\/\//i.test(value) ? url.origin : '';
    return origin+url.pathname+url.search;
  } catch {
    return '-';
  }
}

export function requestLogger(options={}) {
  return morgan((tokens,req,res)=>{
    const safeTokens=Object.create(tokens);
    safeTokens.url=()=>redactRequestUrl(req.originalUrl || req.url);
    safeTokens.referrer=()=>redactRequestUrl(req.headers.referer || req.headers.referrer);
    return combined(safeTokens,req,res);
  },options);
}
