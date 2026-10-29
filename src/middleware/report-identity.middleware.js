import {supabaseAdmin} from '../config/supabase.config.js';
import {protectReportPayload} from '../services/report-identity.service.js';

// Covers nested mutation/replay records and the global error handler as well as reads.
export function reportIdentityBoundary(db=supabaseAdmin) {
  return (req,res,next)=>{
    // Auth responses contain the requesting account, not report identities.
    // Keep sessions independent of report metadata migrations or outages.
    const pathname=(req.originalUrl??'').split('?')[0];
    if(/^\/api\/auth(?:\/|$)/i.test(pathname)){
      res.set('Cache-Control','no-store');
      return next();
    }
    const sendJson=res.json;
    res.json=function(payload){
      const routeId=req.params?.id??req.params?.reportId;
      void protectReportPayload(db,payload,req.user,routeId).then(safe=>{
        if(res.headersSent)return;
        res.set('Cache-Control','no-store');
        sendJson.call(res,safe);
      }).catch(()=>{
        if(res.headersSent)return;
        res.status(503).set('Cache-Control','no-store');
        sendJson.call(res,{message:'Report privacy protection is temporarily unavailable. Please retry.'});
      });
      return res;
    };
    next();
  };
}
