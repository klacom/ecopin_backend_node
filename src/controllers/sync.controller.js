import { supabaseAdmin as supabase } from '../config/supabase.config.js';

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
                obstruction_level
            } = reportData;

            if (!idempotency_key) {
                results.push({ result: 'error', error_message: 'Missing idempotency_key' });
                continue;
            }

            // Check for existing report with this idempotency_key
            const { data: existingReport, error: checkError } = await supabase
                .from('reports')
                .select('id')
                .eq('idempotency_key', idempotency_key)
                .single();
            
            // if checkError and it's not a PGROUTINE error for 'no rows', handle it
            if (existingReport) {
                results.push({
                    idempotency_key,
                    result: 'duplicate',
                    report_id: existingReport.id
                });
                continue;
            }

            // PostGIS point format
            const point = `POINT(${longitude} ${latitude})`;
            const onPrivateProperty = on_private_property === true || on_private_property === 'true';

            // Insert new report
            const { data: newReport, error: insertError } = await supabase
                .from('reports')
                .insert({
                    user_id,
                    title,
                    description,
                    location: point,
                    on_private_property: onPrivateProperty,
                    property_owner_consent_status: onPrivateProperty ? 'pending' : 'not_required',
                    status: onPrivateProperty ? 'pending_owner_consent' : 'unresolved',
                    validation_status: 'pending_ai_validation', // Media uploaded later
                    scale_level: scale_level || 'medium',
                    obstruction_level: obstruction_level || 'none',
                    idempotency_key
                })
                .select()
                .single();

            if (insertError) {
                results.push({
                    idempotency_key,
                    result: 'error',
                    error_message: insertError.message
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
export const batchSyncTaskUpdates = async (req, res, next) => {
    try {
        const { updates } = req.body;
        const user = req.user;

        if (!Array.isArray(updates)) {
            return res.status(400).json({ message: 'Invalid payload: updates must be an array' });
        }

        const EXECUTION_FIELDS = ['status', 'lifecycle_stage', 'evidence_photos', 'completed_at'];
        const ADMIN_FIELDS = ['priority_level', 'assigned_team', 'issue_category', 'cluster_id'];
        
        const results = [];

        for (const update of updates) {
            const { task_id, client_known_updated_at, payload } = update;

            // Fetch current server state
            const { data: serverTask, error: fetchError } = await supabase
                .from('cleanup_tasks')
                .select('*')
                .eq('id', task_id)
                .single();

            if (fetchError || !serverTask) {
                results.push({ task_id, status: 'error', error_message: 'Task not found' });
                continue;
            }

            // Tier 1: Optimistic Locking Check
            const serverUpdatedAt = new Date(serverTask.updated_at).getTime();
            const clientUpdatedAt = new Date(client_known_updated_at).getTime();

            if (serverUpdatedAt > clientUpdatedAt) {
                // Conflict detected. Proceed to Tier 2: Field-Level Authority
                
                const updatedFields = Object.keys(payload);
                const hasExecutionUpdate = updatedFields.some(f => EXECUTION_FIELDS.includes(f));
                const hasAdminUpdate = updatedFields.some(f => ADMIN_FIELDS.includes(f));

                let conflictResolved = false;

                if (user.role === 'field_crew' && hasExecutionUpdate && !hasAdminUpdate) {
                    // Field crew always wins for execution fields
                    conflictResolved = true;
                } else if (user.role === 'officer' && hasAdminUpdate && !hasExecutionUpdate) {
                    // Officer always wins for admin fields
                    conflictResolved = true;
                }
                
                if (!conflictResolved) {
                    // Tier 3: Escalate to Conflict Queue
                    await supabase.from('sync_conflicts').insert({
                        user_id: user.id,
                        operation_type: 'task_update',
                        operation_payload: payload,
                        conflict_reason: `Unresolvable conflict. Server updated at ${serverTask.updated_at}, client knew ${client_known_updated_at}`,
                        server_state: serverTask
                    });

                    results.push({ 
                        task_id, 
                        status: 'conflict', 
                        server_record: serverTask 
                    });
                    continue;
                }
            }

            // Apply Update (Tier 1 ok OR Tier 2 resolved)
            const { error: updateError } = await supabase
                .from('cleanup_tasks')
                .update({ ...payload, updated_at: new Date().toISOString() })
                .eq('id', task_id);

            if (updateError) {
                results.push({ task_id, status: 'error', error_message: updateError.message });
            } else {
                results.push({ task_id, status: 'success' });
            }
        }

        return res.status(200).json({ results });
    } catch (error) {
        console.error('Error in batchSyncTaskUpdates:', error);
        next(error);
    }
};
