const { createClient } = require('@supabase/supabase-js');

if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required by the backend.');
}

// Server-only client. Never expose this key in index.html or ship it to the browser.
const supabaseAdmin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } }
);

async function verifyAccessToken(token) {
  const { data, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user;
}

async function requireUser(req, res, next) {
  const header = req.headers.authorization || '';
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return res.status(401).json({ error: 'Sign in is required.' });
  try {
    const user = await verifyAccessToken(match[1]);
    if (!user) return res.status(401).json({ error: 'Your session is invalid or expired.' });
    req.user = user;
    next();
  } catch (error) {
    console.error('Supabase token verification failed:', error.message);
    return res.status(401).json({ error: 'Could not verify your session.' });
  }
}

module.exports = { supabaseAdmin, verifyAccessToken, requireUser };
