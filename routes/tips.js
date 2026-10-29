 const express = require('express');
const Stripe = require('stripe');
const { supabaseAdmin, requireUser } = require('../supabase');
const router = express.Router();

router.post('/send-tip', requireUser, async (req, res) => {
  if (process.env.STRIPE_TIPS_ENABLED !== 'true' || !process.env.STRIPE_SECRET_KEY) {
    return res.status(503).json({ error: 'Creator tips are not enabled on this deployment yet.' });
  }
  try {
    const creatorUserId = String(req.body?.creator_user_id || '');
    const amount = Number(req.body?.tip_amount_usd);
    if (!creatorUserId) return res.status(400).json({ error: 'Choose a creator to tip.' });
    if (!Number.isFinite(amount) || amount < 1 || amount > 500) return res.status(400).json({ error: 'Tip amount must be between $1 and $500 USD.' });
    if (creatorUserId === req.user.id) return res.status(400).json({ error: 'You cannot tip your own account.' });

    // This table is supplied in ../sql/creator-payout-accounts.sql. Only server/admin code can read it.
    const { data: payout, error } = await supabaseAdmin.from('creator_payout_accounts')
      .select('user_id,stripe_account_id,charges_enabled,payouts_enabled')
      .eq('user_id', creatorUserId).maybeSingle();
    if (error) throw error;
    if (!payout?.stripe_account_id || !payout.charges_enabled || !payout.payouts_enabled) {
      return res.status(400).json({ error: 'This creator is not set up to receive tips yet.' });
    }

    const { data: profile, error: profileError } = await supabaseAdmin.from('profiles').select('id,username,display_name').eq('id', creatorUserId).maybeSingle();
    if (profileError) throw profileError;
    if (!profile) return res.status(404).json({ error: 'Creator not found.' });

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
    const amountCents = Math.round(amount * 100);
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: [{ price_data: { currency: 'usd', product_data: { name: `Tip for ${profile.display_name || profile.username || 'BMN creator'}`, description: 'Support a creator on BMN Community.' }, unit_amount: amountCents }, quantity: 1 }],
      payment_intent_data: { application_fee_amount: Math.round(amountCents * 0.10), transfer_data: { destination: payout.stripe_account_id }, metadata: { sender_user_id: req.user.id, creator_user_id: creatorUserId } },
      success_url: `${process.env.PUBLIC_SITE_URL}/?tip=success&session_id={CHECKOUT_SESSION_ID}#community-page`,
      cancel_url: `${process.env.PUBLIC_SITE_URL}/#community-page`,
      metadata: { sender_user_id: req.user.id, creator_user_id: creatorUserId }
    });
    return res.status(201).json({ checkout_gateway_url: session.url });
  } catch (error) {
    console.error('Stripe tip checkout failed:', error.message);
    return res.status(500).json({ error: 'Unable to start checkout right now.' });
  }
});

module.exports = router;
