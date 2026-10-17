const WEIGHTS = Object.freeze({ completion: 4.5, repost: 3.5, bookmark: 3, like: 2, comment: 1.5 });

function safeSet(value) { return value instanceof Set ? value : new Set(Array.isArray(value) ? value.map(String) : []); }
function extractTags(video) {
  const source = [video.caption, video.content, ...(Array.isArray(video.hashtags) ? video.hashtags : []), ...(Array.isArray(video.tags) ? video.tags : [])].join(' ');
  return [...new Set((source.match(/#[\p{L}\p{N}_]+/gu) || []).map(tag => tag.slice(1).toLowerCase()))];
}

function calculateAssetRankScore(video, preferences = {}, now = Date.now()) {
  const id = String(video.id ?? video.video_id ?? '');
  const completed = safeSet(preferences.completed_video_ids);
  const liked = safeSet(preferences.liked_video_ids);
  const reposted = safeSet(preferences.reposted_video_ids);
  const bookmarked = safeSet(preferences.bookmarked_video_ids);
  const commented = safeSet(preferences.commented_video_ids);
  let score = 0;
  if (completed.has(id)) score += WEIGHTS.completion;
  if (liked.has(id)) score += WEIGHTS.like;
  if (reposted.has(id)) score += WEIGHTS.repost;
  if (bookmarked.has(id)) score += WEIGHTS.bookmark;
  if (commented.has(id)) score += WEIGHTS.comment;
  const preferred = preferences.preferred_tags || {};
  for (const tag of extractTags(video)) score += Math.max(0, Number(preferred[tag]) || 0) * 1.2;
  const createdAt = Date.parse(video.created_at || '');
  const ageHours = Number.isFinite(createdAt) ? Math.max(0, (now - createdAt) / 3600000) : 168;
  return (score + 0.05) / Math.log(ageHours + 2);
}

function generateRankedFypArray(videoPool, preferences = {}) {
  return [...(videoPool || [])].map((video, index) => ({ video, index, score: calculateAssetRankScore(video, preferences) }))
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map(item => item.video);
}

module.exports = { WEIGHTS, calculateAssetRankScore, generateRankedFypArray };
