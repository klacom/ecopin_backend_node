import { processNextPlanningJob } from '../modules/optimization/services/planJobs.service.js';

let timer;
let running = false;

export function startPlanningWorker() {
  if (timer) return;
  async function tick() {
    if (running) return;
    running = true;
    try { await processNextPlanningJob(); }
    catch (error) { console.error('Planning worker failed to claim a job', error); }
    finally { running = false; }
  }
  timer = setInterval(tick, 2000);
  timer.unref?.();
  void tick();
}

export function stopPlanningWorker() {
  if (timer) clearInterval(timer);
  timer = null;
}
