import {maskReportIdentity,publisherDisclosure} from './report-identity.service.js';
function extractRejectionReason(row) {
  if (!row) return null;
  if (typeof row.rejection_reason === 'string' && row.rejection_reason.trim()) {
    return row.rejection_reason.trim();
  }
  if (typeof row.notes === 'string') {
    if (row.notes.includes('Officer rejection reason:')) {
      return row.notes.split('Officer rejection reason:')[1]?.trim() || null;
    }
    if (row.validation_status === 'rejected' && !row.notes.startsWith('Reporter requested manual review:')) {
      return row.notes.trim() || null;
    }
  }
  return null;
}
export const PUBLIC_REPORT_FIELDS = 'id,title,description,issue_type,status,cluster_id,created_at,updated_at,stage,is_overdue,severity_score,severity_level,lifecycle_state,breached_at,validation_status,location,latitude,longitude,location_precision,street_address,barangay,city,sla_started_at,deadline_at';

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

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function readReportForViewer(db, id, viewer) {
  if (!id || !UUID_REGEX.test(id)) return null;
  if (viewer?.id) {
    const {data,error} = await db.rpc('read_authorized_report_detail',{
      actor:viewer.id,report_id:id
    });
    if (error) throw error;
    if (data) {
      const consent = publisherDisclosure(data).publisher_disclosed;
      const pubName = consent && data.profiles?.full_name ? data.profiles.full_name : 'Anonymous';
      return {
        report: maskReportIdentity({
          ...data,
          rejection_reason: extractRejectionReason(data) || data.rejection_reason || null,
          publisher_name: pubName,
          publisher_disclosed: consent
        },viewer),
        detail: true
      };
    }

    if (viewer.role === 'field_crew') {
      try {
        const { data: rep } = await db.from('reports')
          .select('*, profiles(id, full_name, data_consent)')
          .eq('id', id)
          .maybeSingle();
        if (rep?.cleanup_task_id) {
          const { data: task } = await db.from('cleanup_tasks')
            .select('status, route_status, assigned_crew_ids, assigned_field_crew_id')
            .eq('id', rep.cleanup_task_id)
            .maybeSingle();
          if (task && ['created','pending','assigned','en_route','in_progress','partially_completed'].includes(task.status) && task.route_status === 'ready') {
            let isAssigned = task.assigned_crew_ids?.includes(viewer.id);
            if (!isAssigned && task.assigned_field_crew_id) {
              const { data: crew } = await db.from('field_crews').select('team_lead_profile_id, member_profile_ids').eq('id', task.assigned_field_crew_id).maybeSingle();
              if (crew && (crew.team_lead_profile_id === viewer.id || crew.member_profile_ids?.includes(viewer.id))) {
                isAssigned = true;
              }
            }
            if (isAssigned) {
              const consent = publisherDisclosure(rep).publisher_disclosed;
              const pubName = consent && rep.profiles?.full_name ? rep.profiles.full_name : 'Anonymous';
              return {
                report: maskReportIdentity({
                  ...rep,
                  rejection_reason: extractRejectionReason(rep) || rep.rejection_reason || null,
                  publisher_name: pubName,
                  publisher_disclosed: consent
                },viewer),
                detail: true
              };
            }
          }
        }
      } catch (_) {}
    }
  }
  const {data:report,error:readError} = await db.from('public_reports')
    .select(PUBLIC_REPORT_FIELDS)
    .eq('id',id).maybeSingle();
  if (readError) throw readError;
  if (!report) return null;

  // Resolve citizen publisher information safely respecting data_consent
  let publisher_name = 'Anonymous';
  let publisher_disclosed = false;
  try {
    const { data: repOwner } = await db.from('reports')
      .select('hide_identity, profiles(full_name, data_consent)')
      .eq('id', id)
      .maybeSingle();
    if (publisherDisclosure(repOwner).publisher_disclosed) {
      publisher_name = repOwner.profiles.full_name;
      publisher_disclosed = true;
    }
  } catch (err) {
    // Graceful fallback to Anonymous
  }

  return {
    report: {
      ...report,
      rejection_reason: extractRejectionReason(report) || report.rejection_reason || null,
      publisher_name,
      publisher_disclosed
    },
    detail: false
  };
}

export function canReadReportEvidence(access) {
  return Boolean(access && (access.detail || access.report.location_precision === 'exact'));
}
