export const PUBLIC_REPORT_FIELDS = 'id,title,description,issue_type,status,cluster_id,created_at,updated_at,stage,is_overdue,severity_score,severity_level,lifecycle_state,breached_at,validation_status,location,latitude,longitude,location_precision';

export function reportPage(query = {}) {
  const limit = Number(query.limit ?? 200);
  const page = Number(query.page ?? 1);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500 ||
      !Number.isSafeInteger(page) || page < 1 || page > 500) {
    const error = new Error('Use an integer limit from 1 to 500 and page from 1 to 500');
    error.statusCode = 400;
    throw error;
  }
  return {limit, offset:(page - 1) * limit};
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function readReportForViewer(db, id, viewer) {
  if (!id || !UUID_REGEX.test(id)) return null;
  if (viewer?.id) {
    const {data,error} = await db.rpc('read_authorized_report_detail',{
      actor:viewer.id,report_id:id
    });
    if (error) throw error;
    if (data) return {report:data,detail:true};
  }
  const {data:report,error:readError} = await db.from('public_reports')
    .select(PUBLIC_REPORT_FIELDS)
    .eq('id',id).maybeSingle();
  if (readError) throw readError;
  return report ? {report,detail:false} : null;
}

export function canReadReportEvidence(access) {
  return Boolean(access && (access.detail || access.report.location_precision === 'exact'));
}
