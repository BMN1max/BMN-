'use strict';
// Background worker: sweepers -> queue -> handlers, with leases, retries, dead-lettering, heartbeat and health checks.
// Duplicate processing is prevented in the database: jobs are claimed with FOR UPDATE SKIP LOCKED + a lease, every job has an
// idempotency key, and every commit function is idempotent. Several workers (or a restarted one) are therefore safe.
const os = require('node:os');
const { activeRules } = require('./rules/defaults');
const { sleep } = require('./lib/util');

const JOB_FLAGS = { analyze_content: 'moderation_analysis', assess_account: 'account_risk_scoring', evaluate_verification: 'verification_evaluation' };
const ALWAYS = ['reverse_action', 'provider_healthcheck', 'purge_retention', 'expire_restrictions', 'apply_action'];

function createWorker({ store, handlers, workerId, version = 'pi-2.0', log = console, now = () => Date.now() }) {
  const id = workerId || `${os.hostname()}:${process.pid}`.slice(0, 190);
  const stats = { succeeded: 0, failed: 0, lastError: null, lastHealthAt: 0, lastPurgeAt: 0 };
  let busy = false, timer = null, stopped = false;

  async function heartbeat(meta = {}) {
    try { await store.rpc('pi_worker_heartbeat', { p_worker: id, p_version: version, p_succeeded: stats.succeeded, p_failed: stats.failed, p_last_error: stats.lastError, p_meta: meta }); } catch (e) { log.error?.('[pi] heartbeat failed:', e.message); }
  }

  async function tick() {
    if (busy) return { skipped: 'previous tick still running' };       // never overlap with itself
    busy = true;
    const out = { claimed: 0, ok: 0, failed: 0 };
    try {
      let rt;
      try { rt = await store.rpc('pi_get_runtime_config'); } catch (e) { stats.lastError = e.message; await heartbeat({ state: 'config_unavailable' }); return { error: 'config unavailable' }; }
      if (rt.halted) { await heartbeat({ state: 'halted' }); return { halted: true }; }
      const ws = activeRules(rt, 'worker_settings').config;
      const on = (k) => !!rt.flags?.[k]?.enabled;

      // sweepers (each is a no-op in SQL when its flag is off)
      const sweep = async (fn, args) => { try { await store.rpc(fn, args); } catch (e) { stats.lastError = `${fn}: ${e.message}`; log.error?.('[pi]', stats.lastError); } };
      await sweep('pi_expire_automated');
      if (on('moderation_analysis')) await sweep('pi_enqueue_new_content', { p_limit: Math.min(Number(ws.scan_batch) || 100, 1000) });
      if (on('account_risk_scoring')) await sweep('pi_enqueue_account_assessments', { p_limit: 100 });
      if (on('verification_evaluation')) await sweep('pi_enqueue_verification_evaluations', { p_limit: 50 });
      if (now() - stats.lastHealthAt > 60000) { stats.lastHealthAt = now(); await sweep('pi_system_health'); }
      if (now() - stats.lastPurgeAt > 24 * 3600 * 1000) { stats.lastPurgeAt = now(); await sweep('pi_purge_retention'); }

      const types = ALWAYS.slice(); for (const [t, f] of Object.entries(JOB_FLAGS)) if (on(f)) types.push(t);
      const jobs = (await store.rpc('pi_claim_jobs', { p_worker: id, p_limit: Math.min(Number(ws.batch_size) || 10, 100), p_lease: '5 minutes', p_types: types })) || [];
      out.claimed = jobs.length;
      for (const job of jobs) {
        const h = handlers[job.job_type];
        try {
          if (!h) throw new Error('no handler for ' + job.job_type);
          await h(job, rt);
          await store.rpc('pi_complete_job', { p_job_id: job.id, p_worker: id });
          stats.succeeded++; out.ok++;
        } catch (e) {
          stats.failed++; out.failed++; stats.lastError = `${job.job_type}: ${e.message}`.slice(0, 400);
          log.error?.('[pi] job failed', job.id, stats.lastError);
          try { await store.rpc('pi_fail_job', { p_job_id: job.id, p_worker: id, p_error: String(e.message || e).slice(0, 500), p_retry_in: null }); } catch (e2) { log.error?.('[pi] could not record failure', e2.message); }
        }
      }
      await heartbeat({ claimed: out.claimed });
      return out;
    } finally { busy = false; }
  }

  function start() {
    stopped = false;
    const loop = async () => {
      if (stopped) return;
      let delay = 15000;
      try { const r = await tick(); if (r && r.error) delay = 60000; } catch (e) { log.error?.('[pi] tick crashed:', e.message); delay = 30000; }
      if (!stopped) timer = setTimeout(loop, delay);
    };
    timer = setTimeout(loop, 2000);
    return { stop };
  }
  function stop() { stopped = true; if (timer) clearTimeout(timer); }
  return { id, tick, start, stop, stats };
}
module.exports = { createWorker, JOB_FLAGS };
