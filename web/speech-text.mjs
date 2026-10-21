// Deterministic transcript cleanup; no recognition or network calls.
// Aligned with ios/Shared/HerSpeechText.swift.
const ADDRESS_PATTERN = /[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s<>"`，。！？；：、（）【】「」『』《》]+|www\.[^\s<>"`，。！？；：、（）【】「」『』《》]+|[\p{L}\p{M}\p{N}._%+\-]+@[\p{L}\p{M}\p{N}.\-]+\.[\p{L}\p{M}\p{N}]+/giu;

function requireText(value) {
  if (typeof value !== "string") throw new TypeError("Speech text must be a string.");
}

function codeRanges(text) {
  const ranges = [];
  let index = 0;
  while (index < text.length) {
    const marker = text.charCodeAt(index);
    if (marker !== 96 && marker !== 126) { index += 1; continue; }
    let openingEnd = index + 1;
    while (openingEnd < text.length && text.charCodeAt(openingEnd) === marker) openingEnd += 1;
    const count = openingEnd - index;
    if (marker === 126 && count < 3) { index = openingEnd; continue; }
    const fenced = count >= 3;
    let end = openingEnd;
    while (end < text.length) {
      const value = text.charCodeAt(end);
      if (!fenced && (value === 10 || value === 13)) break;
      if (value === marker) {
        let closingEnd = end + 1;
        while (closingEnd < text.length && text.charCodeAt(closingEnd) === marker) closingEnd += 1;
        if (closingEnd - end >= count) { end = closingEnd; break; }
        end = closingEnd;
      } else end += 1;
    }
    ranges.push([index, end]);
    index = end;
  }
  return ranges;
}

function protectedRanges(text) {
  const ranges = codeRanges(text);
  // Fresh RegExp state also makes recursive rewrite callbacks safe.
  const addresses = new RegExp(ADDRESS_PATTERN.source, ADDRESS_PATTERN.flags);
  for (const match of text.matchAll(addresses)) {
    ranges.push([match.index, match.index + match[0].length]);
  }
  ranges.sort((left, right) => left[0] - right[0] || right[1] - left[1]);
  const merged = [];
  for (const range of ranges) {
    const last = merged[merged.length - 1];
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1]);
    else merged.push([...range]);
  }
  return merged;
}

function pronouns(text) {
  return text.replace(/[他它]/gu, "她");
}

/** He/him/it, 牠/祂, URLs, emails and explicit Markdown code remain intact. */
export function feminineSpeechText(text) {
  return processSpeechText(text);
}

/**
 * Process ordinary spans once: rewrite, then 他/它 -> 她.
 * Do not run a whole-string rewrite again on this result.
 * Undelimited arbitrary code and split word fragments are not inferred.
 */
export function processSpeechText(text, { rewrite = (value) => value } = {}) {
  requireText(text);
  if (typeof rewrite !== "function") throw new TypeError("rewrite must be a function.");
  let result = "";
  let cursor = 0;
  function plain(value) {
    const rewritten = rewrite(value);
    requireText(rewritten);
    return pronouns(rewritten);
  }
  for (const [start, end] of protectedRanges(text)) {
    if (start > cursor) result += plain(text.slice(cursor, start));
    result += text.slice(start, end);
    cursor = end;
  }
  if (cursor < text.length) result += plain(text.slice(cursor));
  return result;
}

/** Only ASCII word blocks get a new space; all existing content is retained. */
export function joinSpeechSegments(left, right) {
  requireText(left);
  requireText(right);
  if (!left || !right) return left + right;
  return left + (/[A-Za-z0-9_]$/u.test(left) && /^[A-Za-z0-9_]/u.test(right) ? " " : "") + right;
}
