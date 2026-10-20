import { VoiceController } from './voice.mjs';
import { prepareRules, rewriteText } from './rewrite.mjs';

const $ = id => document.getElementById(id);
const source = $('source');
const result = $('result');
let rules = [];
let rulesLoaded = false;
let selectionOnly = null;
const labels = { friendly: '友好表达', community: '社群借字', original: '保留措辞 · 她优先' };

function render() {
  const input = selectionOnly ? source.value.slice(selectionOnly.start, selectionOnly.end) : source.value;
  const output = rewriteText(input, rules, { mode: $('mode').value, traditional: $('traditional').checked });
  result.value = output.text;
  $('source-count').textContent = [...source.value].length + ' 字';
  $('result-count').textContent = [...output.text].length + ' 字';
  $('result-label').textContent = (selectionOnly ? '仅选区 · ' : '') + labels[$('mode').value];
  $('selection').textContent = selectionOnly ? '恢复处理全文' : '仅处理选中文字';
  const pronouns = (input.match(/他/gu) || []).length;
  $('changes').textContent = output.changes.length || pronouns
    ? `措辞调整 ${output.changes.length} 处 · 他→她 ${pronouns} 处` : '';
  $('copy').disabled = !output.text;
  if (!rulesLoaded) $('rules-status').textContent = '词包未就绪，暂仅执行「他→她」';
}

async function loadRules() {
  $('reload').hidden = true;
  try {
    const response = await fetch('./rules.json', { cache: 'no-store' });
    if (!response.ok) throw new Error('load failed');
    const data = await response.json();
    rules = prepareRules(data);
    rulesLoaded = true;
    render();
    $('rules-status').textContent = `${data.packs.length} 个共享词包 · ${rules.length} 条规则`;
  } catch {
    rulesLoaded = false;
    rules = [];
    render();
    $('reload').hidden = false;
  }
}

const voice = new VoiceController({
  onState(state, message) {
    const active = ['starting', 'listening', 'stopping'].includes(state);
    $('start').disabled = active || !voice.supported;
    $('start').textContent = state === 'error' ? '重新尝试听写' : source.value ? '继续听写' : '开始听写';
    $('stop').disabled = !active || state === 'stopping';
    $('language').disabled = active;
    $('state-dot').classList.toggle('active', active);
    $('voice-title').textContent = ({ starting: '正在连接', listening: '正在聆听', stopping: '正在结束', error: '听写暂不可用' })[state] || '准备听写';
    $('voice-status').textContent = message;
  },
  onInterim(text) { $('interim').textContent = text ? '正在识别：' + text : ''; },
  onFinal(text) { selectionOnly = null; source.value += text; render(); },
  onTick(seconds) { $('timer').textContent = `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`; },
});

$('start').addEventListener('click', () => {
  // An error provider may omit onend; cancel invalidates that old session before retry.
  if (voice.state === 'error') voice.cancel();
  voice.start($('language').value);
});
$('stop').addEventListener('click', () => voice.stop());
$('clear').addEventListener('click', () => {
  voice.cancel();
  selectionOnly = null;
  source.value = '';
  $('action-status').textContent = '本页文字已清空。';
  render();
  source.focus();
});
$('copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(result.value);
    $('action-status').textContent = '结果已复制。';
  } catch {
    result.focus();
    result.select();
    $('action-status').textContent = '浏览器未允许自动复制，已选中结果，请用系统复制快捷键。';
  }
});
$('selection').addEventListener('click', () => {
  if (selectionOnly) {
    selectionOnly = null;
    $('action-status').textContent = '已恢复处理全文。';
  } else {
    const start = source.selectionStart;
    const end = source.selectionEnd;
    if (start === end) { $('action-status').textContent = '请先在左侧原文中选中需要单独校对的文字。'; return; }
    selectionOnly = { start, end };
    $('action-status').textContent = '右侧现在仅包含选区结果；原文仍保留。';
  }
  render();
});
source.addEventListener('input', () => { selectionOnly = null; $('action-status').textContent = ''; render(); });
$('mode').addEventListener('change', render);
$('traditional').addEventListener('change', render);
$('reload').addEventListener('click', loadRules);
window.addEventListener('pagehide', () => voice.destroy());
// Back/forward restoration must not retain text from a previous page instance.
window.addEventListener('pageshow', event => { if (event.persisted) location.reload(); });
if (!voice.supported) {
  $('start').disabled = true;
  $('voice-status').textContent = '当前浏览器不支持语音识别。请尝试支持 SpeechRecognition 的浏览器，或直接输入文字。';
}
source.value = '';
render();
loadRules();
