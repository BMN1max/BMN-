'use strict';
// Small shared helpers. No dependencies.
const crypto = require('node:crypto');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (v) => typeof v === 'string' && UUID_RE.test(v);
const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const round4 = (n) => Math.round(n * 10000) / 10000;
const sha256Hex = (s) => crypto.createHash('sha256').update(String(s), 'utf8').digest('hex');
const hmacHex = (key, s) => crypto.createHmac('sha256', String(key)).update(String(s), 'utf8').digest('hex');

// Combine independent evidence weights (each 0..1): 1 - (1-a)(1-b)... Never exceeds 0.99.
function noisyOr(weights) {
  let miss = 1;
  for (const w of weights) miss *= 1 - clamp(Number(w) || 0, 0, 0.99);
  return round4(clamp(1 - miss, 0, 0.99));
}

// Error with an HTTP-ish status and a stable code. `expose` = safe to show the owner; otherwise a generic message is sent.
class PiError extends Error {
  constructor(message, { status = 500, code = 'internal', expose = false, cause } = {}) {
    super(message);
    this.name = 'PiError';
    this.status = status; this.code = code; this.expose = expose;
    if (cause) this.cause = cause;
  }
}

// Map a Postgres / PostgREST error from the pi_ functions onto a PiError.
function mapDbError(error) {
  const code = String(error?.code || '');
  const msg = String(error?.message || 'database error');
  if (code === '42501') return new PiError(msg, { status: 403, code: 'forbidden', expose: true, cause: error });
  if (code === '22023' || code === '23514' || code === '22P02') return new PiError(msg, { status: 400, code: 'invalid', expose: true, cause: error });
  if (code === 'P0002') return new PiError(msg, { status: 404, code: 'not_found', expose: true, cause: error });
  if (code === 'P0001') return new PiError(msg, { status: 409, code: 'conflict', expose: true, cause: error });
  if (code === '55000') return new PiError(msg, { status: 409, code: 'not_available', expose: true, cause: error });
  return new PiError(msg, { status: 500, code: 'db_error', expose: false, cause: error });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
module.exports = { UUID_RE, isUuid, clamp, round4, sha256Hex, hmacHex, noisyOr, PiError, mapDbError, sleep };
