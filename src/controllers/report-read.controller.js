import {supabaseAdmin as db} from '../config/supabase.config.js';
import {PUBLIC_REPORT_FIELDS,reportPage,readReportForViewer} from '../services/report-access.service.js';

async function enrichReportsWithTasks(reports) {
  if (!Array.isArray(reports) || reports.length === 0) return reports;
  const ids = reports.map(r => r.id).filter(Boolean);
  if (ids.length === 0) return reports;
  try {
    const directMap = new Map();
    const chunkSize = 80;
    for (let i = 0; i < ids.length; i += chunkSize) {
      const chunk = ids.slice(i, i + chunkSize);
      const { data: directRows, error } = await db.from('reports')
        .select('id, cleanup_task_id, before_photos, after_photos')
        .in('id', chunk);
      if (error) {
        console.warn('[enrichReportsWithTasks] Warning fetching task mapping chunk:', error.message);
        break;
      }
      if (directRows) {
        directRows.forEach(d => directMap.set(d.id, d));
      }
    }
    reports.forEach(r => {
      const direct = directMap.get(r.id);
      r.cleanup_task_id = direct?.cleanup_task_id || r.cleanup_task_id || null;
      if (direct?.before_photos) r.before_photos = direct.before_photos;
      if (direct?.after_photos) r.after_photos = direct.after_photos;
    });
  } catch (err) {
    console.warn('[enrichReportsWithTasks] Unexpected error:', err.message);
  }
  return reports;
}

async function reportList(req,res,next,clusterId) {
  try {
    const {limit,offset} = reportPage(req.query);
    const staffCluster = clusterId && ['officer','admin','field_crew'].includes(req.user?.role);
    let query = db.from(staffCluster ? 'reports_view' : 'public_reports')
      .select(staffCluster ? '*' : PUBLIC_REPORT_FIELDS);
    if (clusterId) query = query.eq('cluster_id',clusterId);
    const {data,error} = await query.order('created_at',{ascending:false})
      .order('id',{ascending:false}).range(offset,offset + limit);
    if (error) throw error;
    const sliced = (data || []).slice(0,limit);
    if (staffCluster) await enrichReportsWithTasks(sliced);
    res.set('X-Has-More',String((data || []).length > limit));
    res.status(200).json(sliced);
  } catch(error) {
    if (error.statusCode === 400) return res.status(400).json({message:error.message});
    next(error);
  }
}
export const getPublicReports = (req,res,next) => reportList(req,res,next);
export const getReportsByClusterId = (req,res,next) => reportList(req,res,next,req.params.clusterId);

export async function getStaffReports(req, res, next) {
  try {
    const {limit, offset} = reportPage(req.query);
    let query = db.from('reports_view').select('*');
    if (req.query.ids !== undefined) {
      const ids = [...new Set(String(req.query.ids).split(','))];
      if (ids.length > 100 || ids.some(id => !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))) {
        return res.status(400).json({message: 'Provide 1 to 100 valid report IDs'});
      }
      query = query.in('id', ids);
    }

    if (req.query.validation_status) {
      query = query.eq('validation_status', req.query.validation_status);
    }
    if (req.query.status) {
      query = query.eq('status', req.query.status);
    }
    const {data, error} = await query
      .order('created_at', {ascending: false})
      .order('id', {ascending: false})
      .range(offset, offset + limit);
    if (error) throw error;
    const sliced = (data || []).slice(0, limit);
    await enrichReportsWithTasks(sliced);
    res.set('X-Has-More', String((data || []).length > limit));
    res.status(200).json(sliced);
  } catch (error) {
    if (error.statusCode === 400) return res.status(400).json({message: error.message});
    next(error);
  }
}

export async function getReportById(req,res,next) {
  try {
    const access = await readReportForViewer(db,req.params.id,req.user);
    if (!access) return res.status(404).json({message:'Report not found'});
    let logs = [];
    if (access.detail) {
      const {data,error} = await db.from('response_log').select('*,profiles(full_name)')
        .eq('report_id',req.params.id).order('created_at',{ascending:false});
      if (error) throw error;
      logs = data || [];
    }
    res.status(200).json({...access.report,response_logs:logs});
  } catch(error) {next(error);}
}
