'use strict';
// Standalone worker process (optional): `node platform-intelligence/server/worker-main.js` as a Render Background Worker.
// Use EITHER this OR PI_WORKER_ENABLED=true inside the web service; running both is safe (jobs are leased) but pointless.
require('dotenv').config();
const { supabaseAdmin } = require('../../supabase');
const { createPlatformIntelligence } = require('./index');
const pi = createPlatformIntelligence({ express: null, supabaseAdmin, requireUser: (q, s, n) => n(), rateLimit: null });
const h = pi.worker.start();
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { h.stop(); setTimeout(() => process.exit(0), 500); });
console.log('[pi] worker started', pi.worker.id);
