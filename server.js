require('dotenv').config();
const http = require('http');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { rateLimit } = require('express-rate-limit');
const { Server } = require('socket.io');
const Stripe = require('stripe');
const { supabaseAdmin, verifyAccessToken } = require('./supabase');
const mediaRouter = require('./routes/media');
const tipsRouter = require('./routes/tips');

const app = express();
const server = http.createServer(app);
const allowedOrigins = new Set((process.env.ALLOWED_ORIGINS || process.env.PUBLIC_SITE_URL || '').split(',').map(s => s.trim()).filter(Boolean));
const corsOrigin = (origin, callback) => {
  if (!origin || allowedOrigins.has(origin)) return callback(null, true);
  return callback(new Error('Origin is not allowed by BMN API CORS policy.'));
};

app.set('trust proxy', 1);
app.use(helmet({ crossOriginResourcePolicy: { policy: 'cross-origin' } }));
app.use(cors({ origin: corsOrigin, methods: ['GET', 'POST'], allowedHeaders: ['Content-Type', 'Authorization', 'Stripe-Signature'] }));

// Stripe webhook must receive the exact raw body for signature verification.
app.post('/api/stripe/webhook', express.raw({ type: 'application/json', limit: '1mb' }), async (req, res) => {
  if (!process.env.STRIPE_WEBHOOK_SECRET || !process.env.STRIPE_SECRET_KEY) return res.status(503).send('Stripe webhook is not configured.');
  let event;
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
    event = stripe.webhooks.constructEvent(req.body, req.headers['stripe-signature'], process.env.STRIPE_WEBHOOK_SECRET);
  } catch (error) {
    console.warn('Stripe webhook signature rejected:', error.message);
    return res.status(400).send('Invalid Stripe signature.');
  }
  try {
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object;
      if (session.payment_status === 'paid') {
        const creatorId = session.metadata?.creator_user_id || session.payment_intent?.metadata?.creator_user_id;
        const senderId = session.metadata?.sender_user_id || session.payment_intent?.metadata?.sender_user_id;
        if (creatorId && senderId) {
          const { error } = await supabaseAdmin.from('creator_tips').upsert({
            stripe_checkout_session_id: session.id,
            sender_user_id: senderId,
            creator_user_id: creatorId,
            amount_total: session.amount_total,
            currency: session.currency,
            payment_status: 'paid',
            paid_at: new Date().toISOString()
          }, { onConflict: 'stripe_checkout_session_id' });
          if (error) throw error;
        }
      }
    }
    return res.json({ received: true });
  } catch (error) {
    console.error('Stripe webhook persistence failed:', error.message);
    return res.status(500).send('Webhook persistence failed.');
  }
});

app.use(express.json({ limit: '1mb' }));
app.get('/health', (_req, res) => res.json({ ok: true, service: 'bmn-community-api' }));
app.use('/api/media', rateLimit({ windowMs: 60_000, limit: 12, standardHeaders: true, legacyHeaders: false }), mediaRouter);
app.use('/api/monetization', rateLimit({ windowMs: 60_000, limit: 8, standardHeaders: true, legacyHeaders: false }), tipsRouter);
app.use((error, _req, res, _next) => {
  if (error.message?.includes('CORS policy')) return res.status(403).json({ error: 'This origin is not allowed.' });
  console.error('API error:', error.message);
  return res.status(500).json({ error: 'Unexpected server error.' });
});

const io = new Server(server, {
  cors: { origin: corsOrigin, methods: ['GET', 'POST'] },
  maxHttpBufferSize: 1e6,
  pingTimeout: 20000,
  pingInterval: 25000
});

io.use(async (socket, next) => {
  try {
    const token = socket.handshake.auth?.accessToken;
    if (!token || typeof token !== 'string') return next(new Error('Authentication required.'));
    const user = await verifyAccessToken(token);
    if (!user) return next(new Error('Session is invalid or expired.'));
    socket.data.user = { id: user.id };
    return next();
  } catch (_error) {
    return next(new Error('Could not authenticate this connection.'));
  }
});

io.on('connection', socket => {
  const senderId = socket.data.user.id;
  socket.join(`user:${senderId}`);
  const recentMessages = [];

  socket.on('send_direct_message', async (payload = {}, acknowledge = () => {}) => {
    try {
      const now = Date.now();
      while (recentMessages.length && now - recentMessages[0] > 60_000) recentMessages.shift();
      if (recentMessages.length >= 30) return acknowledge({ ok: false, error: 'Message rate limit reached. Try again shortly.' });
      recentMessages.push(now);

      const recipientId = String(payload.receiver_id || payload.recipient_id || '');
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(recipientId)) {
        return acknowledge({ ok: false, error: 'Choose a valid recipient.' });
      }
      let content;
      if (payload.message_type === 'media_card') {
        const videoId = String(payload.content?.video_id || '');
        if (!videoId || videoId.length > 120) return acknowledge({ ok: false, error: 'A valid post ID is required.' });
        const { data: post, error: postError } = await supabaseAdmin.from('posts').select('id,user_id,content,created_at').eq('id', videoId).maybeSingle();
        if (postError) throw postError;
        if (!post) return acknowledge({ ok: false, error: 'That post is no longer available.' });
        const link = `${process.env.PUBLIC_SITE_URL || ''}/#post-${encodeURIComponent(post.id)}`;
        content = `🎬 Shared a BMN Community post${post.content ? ': ' + String(post.content).slice(0, 180) : ''}\n${link}`;
      } else {
        content = String(payload.content || '').trim();
      }
      if (!content || content.length > 2000) return acknowledge({ ok: false, error: 'Messages must contain 1–2000 characters.' });
      const { data: recipient, error: recipientError } = await supabaseAdmin.from('profiles').select('id').eq('id', recipientId).maybeSingle();
      if (recipientError) throw recipientError;
      if (!recipient) return acknowledge({ ok: false, error: 'Recipient not found.' });

      const { data: saved, error: saveError } = await supabaseAdmin.from('messages')
        .insert({ sender_id: senderId, recipient_id: recipientId, content })
        .select('id,sender_id,recipient_id,content,created_at,read_at').single();
      if (saveError) throw saveError;
      io.to(`user:${recipientId}`).emit('receive_direct_message', saved);
      socket.emit('message_saved', saved);
      return acknowledge({ ok: true, message: saved });
    } catch (error) {
      console.error('Socket message failed:', error.message);
      return acknowledge({ ok: false, error: 'Message could not be saved.' });
    }
  });
});

const port = Number(process.env.PORT || 4000);
server.listen(port, () => console.log(`BMN Community API and Socket.IO listening on port ${port}`));
