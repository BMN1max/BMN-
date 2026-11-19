'use strict';
// Thin wrapper over the database functions. Every call goes through supabaseAdmin.rpc (service role, server side only).
// `rpc(name, args)` returns the data or throws a PiError (mapDbError). Tests inject a fake client with the same shape.
const { mapDbError } = require('./lib/util');

function createStore(client) {
  if (!client || typeof client.rpc !== 'function') throw new Error('createStore needs a Supabase client');
  async function rpc(name, args = {}) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw mapDbError(error);
    return data;
  }
  return { rpc };
}
module.exports = { createStore };
