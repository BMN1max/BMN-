const test = require('node:test');
const assert = require('node:assert/strict');
const { calculateAssetRankScore, generateRankedFypArray } = require('../src/services/recommendation');

test('personal engagement signals increase a candidate score', () => {
  const video = { id: 'post-1', content: '#editing', created_at: new Date().toISOString() };
  const baseline = calculateAssetRankScore(video, {}, Date.now());
  const personalized = calculateAssetRankScore(video, { liked_video_ids: ['post-1'], preferred_tags: { editing: 2 } }, Date.now());
  assert.ok(personalized > baseline);
});

test('feed ranking returns all candidates and prioritizes a liked candidate', () => {
  const videos = [
    { id: 'old', content: 'general post', created_at: '2026-10-01T00:00:00Z' },
    { id: 'liked', content: '#editing', created_at: '2026-10-10T00:00:00Z' }
  ];
  const ranked = generateRankedFypArray(videos, { liked_video_ids: ['liked'] });
  assert.equal(ranked.length, 2);
  assert.equal(ranked[0].id, 'liked');
});
