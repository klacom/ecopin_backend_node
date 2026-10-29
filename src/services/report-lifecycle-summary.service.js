const buckets=['submitted','verified','assigned','in_progress','resolved','rejected','uncategorized'];
const counts=value=>value && typeof value==='object' && !Array.isArray(value) && Object.values(value).every(n=>Number.isSafeInteger(n)&&n>=0);
const sum=value=>Object.values(value).reduce((a,b)=>a+b,0);

export async function readReportLifecycleSummary(db) {
    const {data,error}=await db.rpc('get_report_lifecycle_summary');
    if (error || !data || !Number.isSafeInteger(data.total) || data.total<0 ||
        !counts(data.byLifecycle) || Object.keys(data.byLifecycle).length!==buckets.length || !buckets.every(key=>Object.hasOwn(data.byLifecycle,key)) ||
        !counts(data.byStatus) || !counts(data.uncategorizedByStatus) ||
        sum(data.byLifecycle)!==data.total || sum(data.byStatus)!==data.total || sum(data.uncategorizedByStatus)!==data.byLifecycle.uncategorized ||
        !Number.isFinite(Date.parse(data.snapshotAt)) || data.classificationVersion!=='pdt25-v1') {
        throw Object.assign(new Error('Report lifecycle statistics are temporarily unavailable. Please retry.'),{statusCode:503});
    }
    return data;
}
