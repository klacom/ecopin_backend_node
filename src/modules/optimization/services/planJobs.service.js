import { randomUUID } from 'node:crypto';
import { supabaseAdmin as db } from '../../../config/supabase.config.js';
import { resolvePlanSettings } from './planningPolicy.js';
import { generateDispatchPlan } from './dispatchPlanner.service.js';
import { generateMixedDispatchPlan } from './mixedPlanner.service.js';

async function rpc(name, args, client = db) {
  const { data, error } = await client.rpc(name, args);
  if (error) throw error;
  return data;
}

export async function enqueuePlan(actor, input, idempotencyKey) {
  const settings = resolvePlanSettings(input);
  return rpc('enqueue_plan_generation', {
    actor, plan_mode: settings.mode, settings, request_key: idempotencyKey ?? null
  });
}

export async function readPlanJob(id, actor) {
  const { data, error } = await db.from('plan_generation_jobs')
    .select('id,status,requested_by,mode,requested_at,started_at,finished_at,plan_id,error_code,solver_diagnostics')
    .eq('id', id).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  if (data.requested_by !== actor) {
    const { data: profile, error: profileError } = await db.from('profiles').select('role').eq('id', actor).single();
    if (profileError) throw profileError;
    if (profile.role !== 'admin') return null;
  }
  return { jobId: data.id, status: data.status, mode: data.mode,
    requestedAt: data.requested_at, startedAt: data.started_at, finishedAt: data.finished_at,
    planId: data.plan_id, errorCode: data.error_code, diagnostics: data.solver_diagnostics };
}

export async function processNextPlanningJob({ generate = generateDispatchPlan,
  generateMixed = generateMixedDispatchPlan, client = db } = {}) {
  const workerToken = randomUUID();
  const job = await rpc('claim_plan_generation', { worker_id: workerToken }, client);
  if (!job) return false;
  try {
    const result = job.mode === 'mixed'
      ? await generateMixed(job.requested_by, job.settings_snapshot,
        { jobId: job.id, workerToken })
      : await generate(job.requested_by, job.settings_snapshot);
    if (job.mode !== 'mixed') {
      const { data, error } = await client.from('dispatch_plans')
        .update({ generation_job_id: job.id }).eq('id', result.plan.id).eq('status', 'draft')
        .select('id').single();
      if (error || !data) throw error ?? new Error('Draft plan was not saved');
    }
    await rpc('finish_plan_generation', { job_id: job.id, worker_id: workerToken,
      result_plan_id: result.plan.id, failure_code: null, diagnostics: result.diagnostics ?? {} }, client);
  } catch (error) {
    const failure = error?.code ?? error?.message ?? 'generation_failed';
    try {
      await rpc('finish_plan_generation', { job_id: job.id, worker_id: workerToken,
        result_plan_id: null, failure_code: String(failure).slice(0, 200), diagnostics: {} }, client);
    } catch (finishError) {
      console.error('Planning job could not be finalized', { jobId: job.id, error: finishError });
    }
  }
  return true;
}
