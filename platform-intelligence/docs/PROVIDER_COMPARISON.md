# AI provider comparison for BMN Platform Intelligence

**Research only. No provider is selected, no account was created, no paid API was called.** Pricing pages were read on 2026-11-14 and change;
re-verify before committing. "UNVERIFIED" means I could not read it on an official page. Dollar figures are USD.

## Headline findings
1. **Google Perspective API is shutting down** (active only through 2026-12-31; new quota requests closed). Not viable.
2. **OpenAI's moderation endpoint is free** and covers text + images, but no video, no documented Nigerian-language support, and it is **not CSAM tooling**. Free-tier limits are tier-based and not published in numbers I could verify, so "free" does **not** automatically mean it supports 50,000 users: confirm rate limits for your account tier.
3. **No provider documents Nigerian Pidgin, Igbo or Hausa.** Only Anthropic's docs name Yoruba. Test every candidate on your own labelled Nigerian content before trusting it.
4. **None of the general classifiers detect CSAM.** AWS and Microsoft say so explicitly. CSAM needs hash-matching (Microsoft PhotoDNA, free to qualified applicants; Cloudflare's CSAM scanning tool; Google's CSAI Match for approved partners). Whether Cloudflare's tool covers R2 is UNVERIFIED.
5. **Video is where costs explode** when billed per minute. Sampling key frames and using an image model is far cheaper.

## Per provider
| Provider | Covers | Price (verified) | Free tier | Notable limits |
|---|---|---|---|---|
| OpenAI omni-moderation | text, images (not video/audio) | free | free; rate limits UNVERIFIED | scores recalibrate on model updates; no CSAM; 40-language test cites no African languages; no retention on this endpoint |
| Anthropic Claude (Haiku-class) | text + images via your own prompt (no built-in categories; no video, send frames) | Haiku 5.5: $0.10 in / $0.50 out per M tokens (half on Batch) | none | you build taxonomy/thresholds; spend cap $500/mo at first tier; data kept up to 30 days (longer if flagged); worst explicit images may be refused; names Yoruba support |
| Google Perspective | text | — | — | **sunset 2026-12-31** |
| Google Vision SafeSearch | images | $1.50 / 1,000 images | first 1,000/mo | 1,800 req/min; no text |
| Google Video Intelligence | video | about $0.10 / min (row not confirmed as explicit-content detection) | first ~1,000 min/mo | expensive at scale |
| AWS Rekognition | images, stored video | $0.0010/image (first 1M); $0.10/video-min | 1,000 images + 60 min/mo for 12 months | JPEG/PNG only; says it does **not** detect CSAM; inputs may be used to improve AWS AI unless you opt out; no text |
| Azure AI Content Safety | text, images | standard price UNVERIFIED (page showed "$-") | 5,000 text + 5,000 images/mo, then stops | trained on 8 languages, none Nigerian; says not for CSAM; some features retire 2027-04-30 |
| Hive (deploy.com) | images, video, text | list: text $0.50/1k, visual $3.00/1k | Developers plan capped at 100 requests/day | video, CSAM, real limits are "contact sales" |
| Sightengine | images, video, text, audio | Starter $29/10k ops; Pro $99/40k ops; overage $0.002/op | 2,000 ops/mo, 1 req/s, no video | text ML covers 7 languages, none African; retention UNVERIFIED |

## Estimated monthly cost (my arithmetic from stated assumptions — not vendor quotes)
Assumptions per monthly active user: 20 text items (<1,000 chars), 2 images, 3 videos of 45 s handled as 5 key frames each.

| Provider | 1k users | 10k users | 50k users |
|---|---|---|---|
| OpenAI (text + images + frames) | $0 | $0 | $0 (if rate limits allow) |
| Claude Haiku 5.5 (text + images + frames) | ~$4 | ~$43 | ~$212 |
| Google SafeSearch (images/frames only, no text) | ~$24 | ~$254 | ~$1,274 |
| AWS Rekognition images/frames (no text) | ~$16 | ~$169 | ~$849 |
| Sightengine, 5 frames/video | ~$83 | ~$749 | ~$3,709 |
| Per-minute video (Google / AWS stored video) | $125–$219 | $2,150–$2,250 | $11,150–$11,250 |
| Azure, Hive | not computable from verified prices | | |

## Suggested direction (my inference, **for your decision**, not a commitment)
A hybrid: a free first-pass classifier for text and sampled frames, a second-pass LLM for Pidgin/Yoruba/slang context and borderline cases,
mandatory human review for serious categories, **a separate hash-matching service for CSAM**, and rules-only fallback when providers are down
(the schema already supports this: `pi_provider_health`, `ai_providers` flag, `skipped` outcomes). Before choosing: (a) get a labelled sample of real BMN content,
(b) measure each candidate on it, (c) confirm OpenAI rate limits and Anthropic data-handling terms are acceptable for your privacy policy,
(d) get legal advice on CSAM reporting duties for a Nigeria-operated service (US 18 U.S.C. 2258A applies to US providers; Nigerian law was NOT verified).

## Sources (official pages)
developers.openai.com/api/docs/guides/moderation · platform.claude.com/docs/en/about-claude/pricing · platform.claude.com/docs/en/api/rate-limits ·
platform.claude.com/docs/en/build-with-claude/multilingual-support · privacy.claude.com/en/articles/7996866 · perspectiveapi.com ·
cloud.google.com/vision/pricing · cloud.google.com/video-intelligence/pricing · protectingchildren.google/tools-for-partners ·
aws.amazon.com/rekognition/pricing · aws.amazon.com/rekognition/faqs · azure.microsoft.com/pricing/details/content-safety ·
learn.microsoft.com/azure/ai-services/content-safety/language-support · deploy.com/pricing · sightengine.com/pricing ·
developers.cloudflare.com/cache/reference/csam-scanning · microsoft.com/photodna · law.cornell.edu/uscode/text/18/2258A
