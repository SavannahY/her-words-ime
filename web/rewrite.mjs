/** Literal, one-pass rewriting of inert rules compiled from the shared packs. */
export function prepareRules(payload) {
  if (payload?.format !== 'her-words-web-rules' || !Array.isArray(payload.rules)) {
    throw new Error('词包格式不正确');
  }
  return payload.rules.map((rule, order) => {
    if (typeof rule.from !== 'string' || !rule.from || typeof rule.to !== 'string'
        || !['exact', 'phrase'].includes(rule.match)) throw new Error('词包规则不正确');
    return Object.freeze({ ...rule, order });
  }).sort((a, b) => b.from.length - a.from.length || a.order - b.order);
}

export function rewriteText(value, rules = [], { mode = 'friendly', traditional = false } = {}) {
  const source = String(value ?? '');
  const changes = [];
  let position = 0;
  const parts = [];
  if (mode === 'original') return { text: source.replaceAll('他', '她'), changes };
  while (position < source.length) {
    let chosen = null;
    let start = Infinity;
    for (const rule of rules) {
      if (rule.match === 'exact' && source !== rule.from) continue;
      const at = source.indexOf(rule.from, position);
      if (at >= 0 && at < start) { start = at; chosen = rule; }
    }
    if (!chosen) { parts.push(source.slice(position)); break; }
    parts.push(source.slice(position, start));
    const field = mode === 'community' && typeof chosen.community === 'string' ? 'community' : 'to';
    const to = traditional && typeof chosen[field + '_traditional'] === 'string'
      ? chosen[field + '_traditional'] : chosen[field];
    parts.push(to);
    changes.push({ from: chosen.from, to });
    position = start + chosen.from.length;
  }
  // Do not re-run replacements through the rule set. The pronoun preference is
  // independent, including in original mode and in replacement strings.
  return { text: parts.join('').replaceAll('他', '她'), changes };
}
