'use strict';
// Text normalisation for the rule engines. The engines see only this normalised text; it is never stored or logged.
const { sha256Hex } = require('./util');

const ZERO_WIDTH = /[​-‏‪-‮⁠-⁤﻿]/g;
const LEET = { '0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', '$': 's', '!': 'i' };

function normalizeText(input, maxLen = 5000) {
  let s = String(input == null ? '' : input);
  if (s.length > maxLen) s = s.slice(0, maxLen);
  s = s.normalize('NFKC').replace(ZERO_WIDTH, '').toLowerCase();
  return s.replace(/\s+/g, ' ').trim();
}

// Same text with common character substitutions undone (to catch "fr33 g1ftcard"). Only used for phrase matching.
function deobfuscate(norm) {
  return norm.replace(/[01345 7@$!]/g, (c) => (c === ' ' ? ' ' : LEET[c] || c)).replace(/(.)\1{2,}/g, '$1$1');
}

function countUrls(norm) {
  const m = norm.match(/\b(?:https?:\/\/|www\.)[^\s]+|\b[a-z0-9-]+\.(?:com|net|org|io|co|ly|me|xyz|top|link|click|info|biz|app|gg|cc|tk|ru|ng)\b(?:\/[^\s]*)?/g);
  return m ? m.length : 0;
}

const SHORTENERS = ['bit.ly', 'tinyurl.com', 't.co', 'goo.gl', 'ow.ly', 'is.gd', 'cutt.ly', 'rb.gy', 'shorturl.at', 'tiny.cc'];
const hasShortener = (norm) => SHORTENERS.some((d) => norm.includes(d));

function wordList(norm) { return norm.split(/[^\p{L}\p{N}']+/u).filter(Boolean); }

// Fraction of words that repeat an earlier word (0 = all different).
function repetitionRatio(words) {
  if (words.length < 6) return 0;
  const seen = new Set(); let rep = 0;
  for (const w of words) { if (seen.has(w)) rep++; else seen.add(w); }
  return rep / words.length;
}

function capsRatio(raw) {
  const letters = String(raw).replace(/[^\p{L}]/gu, '');
  if (letters.length < 20) return 0;
  const upper = letters.replace(/[^\p{Lu}]/gu, '').length;
  return upper / letters.length;
}

// The hash stored with an analysis: of the normalised text plus subject type, so identical content is recognisable
// (duplicate / spam-wave detection and "already analysed") without ever storing the text itself.
const contentHash = (subjectType, norm) => sha256Hex(`${subjectType}\u0000${norm}`);

// Escape a phrase for use inside a RegExp.
const escapeRe = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Levenshtein distance (small strings only; callers cap length).
function levenshtein(a, b) {
  if (a === b) return 0;
  if (!a.length) return b.length; if (!b.length) return a.length;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[b.length];
}

// Lower-case, strip separators and decoration, undo look-alike characters: "Bm_N.Official" -> "bmnofficial".
function nameKey(s) {
  return deobfuscate(String(s || '').normalize('NFKC').replace(ZERO_WIDTH, '').toLowerCase()).replace(/[^\p{L}\p{N}]/gu, '').slice(0, 40);
}
function nameSimilarity(a, b) {
  const x = nameKey(a), y = nameKey(b);
  if (!x || !y) return 0;
  if (x === y) return 1;
  const d = levenshtein(x, y);
  return Math.max(0, 1 - d / Math.max(x.length, y.length));
}

module.exports = { normalizeText, deobfuscate, countUrls, hasShortener, wordList, repetitionRatio, capsRatio, contentHash, escapeRe, levenshtein, nameKey, nameSimilarity };
