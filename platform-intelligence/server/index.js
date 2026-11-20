
'use strict';
// Entry point used by server.js. Everything is OFF by default: with all feature flags disabled the router only answers owner
// requests and the worker is a no-op (it still reports its heartbeat).
const { createStore } = require('./store');
const { createRouter } = require('./router');
const { createHandlers } = require('./handlers');
const { createWorker } = require('./worker');
const { createOpenAiModeration } = require('./providers/openai-moderation');

function createPlatformIntelligence({ express, supabaseAdmin, requireUser, rateLimit, env = process.env, log = console }) {
  const store = createStore(supabaseAdmin);
  const provider = env.OPENAI_API_KEY ? createOpenAiModeration({ apiKey: env.OPENAI_API_KEY, model: env.PI_OPENAI_MODEL || undefined }) : null;
  const handlers = createHandlers({ store, provider, log: (...a) => log.log?.(...a) });
  const worker = createWorker({ store, handlers, log, workerId: env.PI_WORKER_ID || undefined });
  // The standalone background worker does not need Express or an HTTP router.
  const router = express ? createRouter({ express, log, store, requireUser, rateLimit, hashKey: env.PI_HASH_KEY && env.PI_HASH_KEY.length >= 24 ? env.PI_HASH_KEY : null }) : null;
  return { router, worker, store, handlers };
}
module.exports = { createPlatformIntelligence };
