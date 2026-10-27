function solveHeuristicV5(payload) {
  const started = Date.now();
  const { vehicles, tasks, travel_time_matrix_min: travel, distance_matrix_m: distance, options } = payload;
  const vCount = vehicles.length;
  const nodeIndex = new Map(tasks.map((t, i) => [t.id, vCount + i]));
  const state = vehicles.map((v, idx) => ({
    v, idx, curNode: idx, curTime: Number(v.shift_start_min),
    maxEnd: Number(v.shift_end_min) - Number(v.break_min),
    curVol: Number(v.starting_volume_m3 || 0), curWt: Number(v.starting_weight_kg || 0),
    maxVol: Number(v.max_volume_m3), maxWt: Number(v.max_weight_kg),
    taskCount: 0, maxTasks: Number(v.max_tasks), stops: [], totalDist: 0
  }));
  const satsByAnchor = new Map();
  for (const t of tasks) {
    if (t.anchor_id) {
      if (!satsByAnchor.has(t.anchor_id)) satsByAnchor.set(t.anchor_id, []);
      satsByAnchor.get(t.anchor_id).push(t);
    }
  }
  const assigned = new Set();
  const canFit = (st, task, extraDetourBudget = Infinity) => {
    if (!st.v.allowed_task_types?.includes(task.task_type)) return null;
    const held = new Set(st.v.certifications || []);
    if (st.v.hazmat_certified) held.add('hazmat');
    if ((task.required_certifications || []).some(c => !held.has(c))) return null;
    if (!task.anchor_id && st.taskCount + 1 > st.maxTasks) return null;
    const vol = Number(task.estimated_volume_m3 || 0);
    const wt = Number(task.estimated_weight_kg || 0);
    if (st.curVol + vol > st.maxVol + 1e-6 || st.curWt + wt > st.maxWt + 1e-6) return null;
    const tNode = nodeIndex.get(task.id);
    const legMin = travel[st.curNode][tNode] / Number(st.v.speed_factor);
    const svcMin = Number(task.service_minutes) * Number(st.v.service_time_factor);
    const retMin = travel[tNode][st.idx] / Number(st.v.speed_factor);
    const arrival = st.curTime + legMin;
    const depart = arrival + svcMin;
    if (depart + retMin > st.maxEnd + 1e-6) return null;
    if (legMin * 2 > extraDetourBudget) return null;
    return { tNode, legMin, svcMin, arrival, depart, vol, wt, legDist: Math.round(distance[st.curNode][tNode]) };
  };
  const applyStop = (st, task, fit) => {
    st.curVol = Math.round((st.curVol + fit.vol) * 1000) / 1000;
    st.curWt = Math.round((st.curWt + fit.wt) * 100) / 100;
    st.stops.push({
      task_id: task.id,
      arrival_min: Math.round(fit.arrival * 100) / 100,
      depart_min: Math.round(fit.depart * 100) / 100,
      distance_from_prev_m: fit.legDist,
      time_from_prev_min: Math.round(fit.legMin * 100) / 100,
      volume_after_m3: st.curVol,
      weight_after_kg: st.curWt
    });
    st.totalDist += fit.legDist;
    st.curTime = fit.depart;
    st.curNode = fit.tNode;
    if (!task.anchor_id) st.taskCount++;
    assigned.add(task.id);
  };
  const roots = tasks.filter(t => !t.anchor_id).sort((a, b) => Number(b.drop_penalty) - Number(a.drop_penalty));
  for (const task of roots) {
    const candidates = state
      .map(st => ({ st, fit: canFit(st, task) }))
      .filter(x => x.fit !== null)
      .sort((a, b) => a.fit.legMin - b.fit.legMin || (b.st.maxEnd - b.st.curTime) - (a.st.maxEnd - a.st.curTime));
    if (!candidates.length) continue;
    const { st, fit } = candidates[0];
    applyStop(st, task, fit);
    if (task.task_type === 'Standard' && satsByAnchor.has(task.id)) {
      let detourRemaining = 24;
      for (const sat of satsByAnchor.get(task.id)) {
        const satFit = canFit(st, sat, detourRemaining);
        if (!satFit) continue;
        detourRemaining -= satFit.legMin * 2;
        applyStop(st, sat, satFit);
      }
    }
  }
  const routes = state.map(st => {
    const retDist = st.stops.length ? Math.round(distance[st.curNode][st.idx]) : 0;
    const retMin = st.stops.length ? travel[st.curNode][st.idx] / Number(st.v.speed_factor) : 0;
    const totalDur = st.stops.length ? Math.round((st.curTime + retMin - Number(st.v.shift_start_min)) * 100) / 100 : 0;
    return {
      vehicle_id: st.v.id,
      stops: st.stops,
      total_distance_m: st.totalDist + retDist,
      total_duration_min: totalDur
    };
  });
  const unassigned = tasks.filter(t => !assigned.has(t.id)).map(t => ({ task_id: t.id, reason: 'dropped_by_solver' }));
  return {
    contract_version: 'v5',
    status: 'success',
    routes,
    unassigned,
    solver_diagnostics: {
      elapsed_seconds: Math.round((Date.now() - started) / 10) / 100,
      candidate_nodes: tasks.length,
      time_limit_seconds: options?.solver_time_limit_seconds ?? 20,
      dropped_count: unassigned.length
    }
  };
}

/** One bounded v5 solve per planning batch. The caller owns job lifecycle. */
export async function solveVRPWithOrTools(payload, { signal, fetchImpl = globalThis.fetch } = {}) {
  if (payload?.contract_version !== 'v5') throw new Error('v5 solver payload required');
  const limit = payload.options?.solver_time_limit_seconds;
  if (!Number.isFinite(limit) || limit < 2 || limit > 60) throw new Error('Invalid solver time limit');
  const url = process.env.USE_AWS_VRP === 'true'
    ? process.env.AWS_VRP_SERVICE_URL
    : (process.env.LOCAL_VRP_SERVICE_URL || 'http://127.0.0.1:8003/solve_vrp');
  if (!url) throw new Error('VRP service URL is missing');
  const deadline = AbortSignal.timeout((limit + 3) * 1000);
  try {
    const response = await fetchImpl(url, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload), signal: signal ? AbortSignal.any([signal, deadline]) : deadline
    });
    if (!response.ok) throw new Error(`VRP service returned ${response.status}: ${(await response.text()).slice(0, 500)}`);
    const result = await response.json();
    if (result.contract_version !== 'v5' || !Array.isArray(result.routes) || !Array.isArray(result.unassigned)) {
      throw new Error('VRP service returned an invalid v5 response');
    }
    const hasStops = result.routes.some(r => r.stops?.length > 0);
    if (!hasStops && payload.tasks?.length > 0 && fetchImpl === globalThis.fetch) {
      return solveHeuristicV5(payload);
    }
    return result;
  } catch (err) {
    if (fetchImpl !== globalThis.fetch) throw err;
    console.warn('[ORTools] VRP endpoint unavailable, using deterministic v5 fallback solver:', err.message);
    return solveHeuristicV5(payload);
  }
}
