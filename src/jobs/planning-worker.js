import { processNextPlanningJob } from '../modules/optimization/services/planJobs.service.js';

let timer = null;
let running = false;
let currentDelay = 2000;
const MIN_DELAY = 2000;
const MAX_DELAY = 15000;
const BACKOFF_STEP = 3000;

export async function tick() {
  if (running) return false;
  running = true;
  let processed = false;
  try {
    processed = await processNextPlanningJob();
    if (processed) {
      // If a job was claimed and completed, reset delay so any waiting jobs are claimed promptly
      currentDelay = MIN_DELAY;
    } else {
      // If idle, back off gradually up to MAX_DELAY to avoid slamming Supabase with RPC queries
      currentDelay = Math.min(MAX_DELAY, currentDelay + BACKOFF_STEP);
    }
  } catch (error) {
    console.error('Planning worker failed to claim a job', error);
    currentDelay = MAX_DELAY;
  } finally {
    running = false;
  }
  return processed;
}

function scheduleNext() {
  if (timer !== null) {
    clearTimeout(timer);
    timer = null;
  }
  timer = setTimeout(async () => {
    await tick();
    if (timer !== null) {
      scheduleNext();
    }
  }, currentDelay);
  timer.unref?.();
}

export function startPlanningWorker() {
  if (timer) return;
  currentDelay = MIN_DELAY;
  scheduleNext();
  void tick();
}

export function stopPlanningWorker() {
  if (timer) clearTimeout(timer);
  timer = null;
  running = false;
  currentDelay = MIN_DELAY;
}

export function getWorkerState() {
  return { isRunning: running, currentDelay, isScheduled: timer !== null };
}
