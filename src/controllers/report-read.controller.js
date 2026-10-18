import {supabaseAdmin as db} from '../config/supabase.config.js';
import {PUBLIC_REPORT_FIELDS,reportPage,readReportForViewer} from '../services/report-access.service.js';

async function reportList(req,res,next,clusterId) {
  try {
    const {limit,offset} = reportPage(req.query);
    const staffCluster = clusterId && ['officer','admin'].includes(req.user?.role);
    let query = db.from(staffCluster ? 'reports_view' : 'public_reports')
      .select(staffCluster ? '*' : PUBLIC_REPORT_FIELDS);
    if (clusterId) query = query.eq('cluster_id',clusterId);
    const {data,error} = await query.order('created_at',{ascending:false})
      .order('id',{ascending:false}).range(offset,offset + limit);
    if (error) throw error;
    res.set('X-Has-More',String((data || []).length > limit));
    res.status(200).json((data || []).slice(0,limit));
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
    res.set('X-Has-More', String((data || []).length > limit));
    res.status(200).json((data || []).slice(0, limit));
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
