const { createClient } = require('redis');
let client;
let connecting;

function getRedisClient() {
  if (!process.env.REDIS_URL) return null;
  if (!client) {
    client = createClient({ url: process.env.REDIS_URL });
    client.on('error', error => console.error('Redis error:', error.message));
  }
  return client;
}

async function ensureRedis() {
  const redis = getRedisClient();
  if (!redis) return null;
  if (redis.isReady) return redis;
  if (!connecting) connecting = redis.connect().finally(() => { connecting = null; });
  await connecting;
  return redis;
}

async function getCachedUserFypFeed(userId, fallbackFetch) {
  if (!userId) throw new Error('A verified user ID is required for a personalized feed.');
  const key = `user:fyp:v1:${userId}`;
  let redis;
  try {
    redis = await ensureRedis();
    if (redis) {
      const raw = await redis.get(key);
      if (raw) {
        try { return JSON.parse(raw); }
        catch { await redis.del(key); }
      }
    }
  } catch (error) {
    console.warn('Redis unavailable; bypassing cache:', error.message);
  }

  // Do not run the fallback twice if it fails.
  const feed = await fallbackFetch(userId);
  try {
    if (redis?.isReady) await redis.setEx(key, 300, JSON.stringify(feed));
  } catch (error) {
    console.warn('Could not cache FYP:', error.message);
  }
  return feed;
}

async function invalidateUserFyp(userId) {
  try {
    const redis = await ensureRedis();
    if (redis && userId) await redis.del(`user:fyp:v1:${userId}`);
  } catch (error) {
    console.warn('Could not invalidate FYP cache:', error.message);
  }
}

module.exports = { getCachedUserFypFeed, invalidateUserFyp };
