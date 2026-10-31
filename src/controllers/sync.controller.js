import {parseHideIdentity} from '../services/report-identity.service.js';
import {normalizeCitizenIssueType} from '../services/citizen-issue-type.service.js';
import {normalizeCitizenLandmark} from '../services/citizen-landmark.service.js';
import { supabaseAdmin as supabase } from '../config/supabase.config.js';
import { citizenPriorityFields } from '../services/citizen-priority.service.js';

// batchSyncReports handles Tier 1 deduplication
export const batchSyncReports = async (req, res, next) => {
    try {
        const { reports } = req.body;
        
        if (!Array.isArray(reports)) {
            return res.status(400).json({ message: 'Invalid payload: reports must be an array' });
        }

        const user_id = req.user.id;
        const results = [];

        for (const reportData of reports) {
            const {
                idempotency_key,
                title,
                description,
                latitude,
                longitude,
                on_private_property,
                scale_level,
                obstruction_level,
                created_at
            } = reportData;

            if (!idempotency_key) {
                results.push({ result: 'error', error_message: 'Missing idempotency_key' });
                continue;
            }

            // Check for existing report with this idempotency_key
            const { data: existingReport, error: checkError } = await supabase
                .from('reports')
                .select('id, user_id, hide_identity')
                .eq('idempotency_key', idempotency_key)
                .single();
            
            // if checkError and it's not a PGROUTINE error for 'no rows', handle it
            if (existingReport) {
                if(existingReport.user_id!==user_id){
                    results.push({idempotency_key,result:'error',error_message:'Submission key is unavailable.'});continue;
                }
                if(reportData.hide_identity!==undefined&&parseHideIdentity(reportData.hide_identity)!==existingReport.hide_identity){
                    results.push({idempotency_key,result:'error',error_message:'Privacy choice differs from the original submission.'});continue;
                }
                results.push({
                    idempotency_key,
                    result: 'duplicate',
                    report_id: existingReport.id
                });
                continue;
            }

            let priorityFields, hideIdentity, citizenLandmark;
            try {
                priorityFields = citizenPriorityFields(reportData);
                hideIdentity = parseHideIdentity(reportData.hide_identity);
                citizenLandmark = normalizeCitizenLandmark(reportData.citizen_landmark);
            } catch (error) {
                results.push({ idempotency_key, result: 'error', error_message: error.message });
                continue;
            }
            // PostGIS point format
            const point = `POINT(${longitude} ${latitude})`;
            const onPrivateProperty = on_private_property === true || on_private_property === 'true';

            let sanitizedCreatedAt = undefined;
            if (created_at) {
                const parsed = new Date(created_at);
                if (!isNaN(parsed.getTime())) {
                    sanitizedCreatedAt = parsed.toISOString();
                }
            }

            // Insert new report
            const { data: newReport, error: insertError } = await supabase
                .from('reports')
                .insert({
                    user_id,
                    hide_identity: hideIdentity,
                    title,
                    description,
                    citizen_landmark: citizenLandmark,
                    ...(normalizeCitizenIssueType(reportData.issue_type) ? { issue_type: normalizeCitizenIssueType(reportData.issue_type) } : {}),
                    location: point,
                    ...priorityFields,
                    on_private_property: onPrivateProperty,
                    property_owner_consent_status: onPrivateProperty ? 'pending' : 'not_required',
                    status: onPrivateProperty ? 'pending_owner_consent' : 'unresolved',
                    validation_status: 'pending_ai_validation', // Media uploaded later
                    scale_level: scale_level || 'medium',
                    obstruction_level: obstruction_level || 'none',
                    idempotency_key,
                    ...(sanitizedCreatedAt ? { created_at: sanitizedCreatedAt } : {})
                })
                .select()
                .single();

            if (insertError) {
                results.push({
                    idempotency_key,
                    result: 'error',
                    error_message: insertError.message,
                    ...(insertError.hint === 'URGENT_TRUST_LOCKED' ? { error_code: 'URGENT_TRUST_LOCKED' } : {})
                });
            } else {
                results.push({
                    idempotency_key,
                    result: 'created',
                    report_id: newReport.id
                });
            }
        }

        return res.status(200).json({ results });
    } catch (error) {
        console.error('Error in batchSyncReports:', error);
        next(error);
    }
};

// batchSyncTaskUpdates handles Tier 1 optimistic locking, Tier 2 field authority, and Tier 3 conflicts
export const batchSyncTaskUpdates = async (req,res) => {
  res.status(409).json({message:'Timestamp sync is retired. Submit versioned operations to /api/fc/sync/batch.'});
};
