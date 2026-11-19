'use strict';
// OPTIONAL external provider adapter (OpenAI moderation endpoint). OFF unless OPENAI_API_KEY is set AND the owner enables the
// feature flag `moderation_external_provider`. The key is read from the server environment only and is never logged or returned.
// Text is sent only for items the rules engine could not already settle and never for private messages. This adapter has been tested
// ONLY against a mocked fetch: its live behaviour, pricing and rate limits are not verified.
const MAP = {            // provider category -> BMN category
  'harassment': 'harassment_bullying', 'harassment/threatening': 'threats_violence', 'hate': 'hate_speech', 'hate/threatening': 'hate_speech',
  'violence': 'threats_violence', 'violence/graphic': 'threats_violence', 'sexual': 'prohibited_sexual_content', 'sexual/minors': 'sexual_exploitation',
  'self-harm': 'threats_violence', 'self-harm/intent': 'threats_violence', 'self-harm/instructions': 'threats_violence', 'illicit': 'dangerous_prohibited', 'illicit/violent': 'dangerous_prohibited'
};
function createOpenAiModeration({ apiKey, fetchImpl = globalThis.fetch, model = 'omni-moderation-latest', timeoutMs = 8000, endpoint = 'https://api.openai.com/v1/moderations' } = {}) {
  const name = 'openai_moderation';
  const enabled = !!apiKey;
  async function score(text) {
    if (!enabled) throw new Error('provider not configured');
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      const res = await fetchImpl(endpoint, { method: 'POST', signal: ctl.signal, headers: { 'content-type': 'application/json', authorization: 'Bearer ' + apiKey },
        body: JSON.stringify({ model, input: String(text).slice(0, 8000) }) });
      if (!res.ok) throw new Error('provider HTTP ' + res.status);
      const j = await res.json();
      const r = j && j.results && j.results[0];
      if (!r || typeof r.category_scores !== 'object') throw new Error('unexpected provider response');
      const out = {};
      for (const [k, v] of Object.entries(r.category_scores)) { const cat = MAP[k]; if (cat && typeof v === 'number') out[cat] = Math.max(out[cat] || 0, v); }
      return { scores: out, model: j.model || model };
    } finally { clearTimeout(t); }
  }
  return { name, enabled, score };
}
module.exports = { createOpenAiModeration, MAP };
