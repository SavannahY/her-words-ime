import assert from 'node:assert/strict';
import { prepareRules, rewriteText } from './rewrite.mjs';
let input = '';
for await (const chunk of process.stdin) input += chunk;
const { payload, cases } = JSON.parse(input);
const original = JSON.stringify(payload);
const rules = prepareRules(payload);
let checked = 0;
for (const item of cases) {
  assert.equal(rewriteText(item.input, rules, item.options).text, item.expected, JSON.stringify(item));
  checked += 1;
}
assert.equal(JSON.stringify(payload), original, 'compiled data must remain immutable');
assert.equal(rewriteText('他她其他', rules, { mode: 'original' }).text, '她她其她');
assert.equal(rewriteText('你妈的生日', rules).text, '你妈的生日');
assert.equal(rewriteText('她妈的名字', rules).text, '她妈的名字');
assert.equal(rewriteText('黑寡妇', rules).text, '黑寡妇');
assert.equal(rewriteText('我嫉妒他', rules).text, '我嫉妒她', 'exact must not become substring');
assert.equal(rewriteText('绿茶婊子', rules).text, '表里不一的人');
assert.equal(rewriteText('心机婊行为', rules).text, '工于心计的行为');
assert.equal(rewriteText('潑婦', rules, { traditional: true }).text, '蠻橫無理的人');
assert.equal(rewriteText('心機婊', rules, { traditional: true }).text, '工於心計的人');
// Literal matching, leftmost/longest priority, and no recursive rewriting.
const artificial = prepareRules({ format: 'her-words-web-rules', rules: [
  { from: '[x]', to: 'literal', match: 'phrase' },
  { from: 'abc', to: 'long', match: 'phrase' },
  { from: 'ab', to: 'short', match: 'phrase' },
  { from: 'long', to: 'recursive', match: 'phrase' },
] });
assert.equal(rewriteText('[x] abc', artificial).text, 'literal long');
assert.throws(() => prepareRules({ rules: [] }));
console.log(`Verified ${checked} shared-pack examples and 11 boundary/privacy regressions.`);
