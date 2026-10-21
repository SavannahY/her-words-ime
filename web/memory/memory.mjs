let state;
const $ = id => document.getElementById(id);
const error = message => { $('error').hidden = !message; $('error').textContent = message || ''; };
const button = (title, action, className = 'secondary') => { const item = document.createElement('button'); item.type = 'button'; item.className = className; item.textContent = title; item.addEventListener('click', action); return item; };
async function change(payload, message) {
  error('');
  try {
    const response = await fetch('/api/change', {method:'POST',headers:{'Content-Type':'application/json','X-Her-Memory-Token':state.token},body:JSON.stringify(payload)});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '保存失败，请重试。');
    state = result; render(); $('status').textContent = message;
  } catch (reason) { error(reason.message); }
}
function render() {
  $('learning').checked = state.learning;
  $('location').textContent = '本地目录：' + state.directory;
  const query = $('search').value.toLocaleLowerCase();
  $('entries').replaceChildren(); $('blocked').replaceChildren();
  const entries = state.entries.filter(item => (item.text + '\n' + item.input).toLocaleLowerCase().includes(query));
  for (const item of entries) {
    const row = document.createElement('div'); row.className = 'entry';
    const info = document.createElement('div'), title = document.createElement('strong'), meta = document.createElement('span');
    title.textContent = item.text; meta.className = 'meta'; meta.textContent = item.input + ' · ' + (item.manual ? '手动保存' : '确认过 ' + item.count + ' 次');
    info.append(title, meta); const actions = document.createElement('div'); actions.className = 'actions';
    actions.append(button('修改输入码', () => { $('word').value = item.text; $('reading').value = item.input; $('reading').focus(); $('add-form').scrollIntoView({behavior:'smooth',block:'center'}); }), button('忘记', () => change({action:'forget',text:item.text}, '已忘记这个词的个性化记忆。')), button('不再推荐', () => change({action:'block',text:item.text}, '已停止推荐这个词；下次输入立即生效。')));
    row.append(info,actions); $('entries').append(row);
  }
  if (!entries.length) { const empty = document.createElement('p'); empty.className='empty'; empty.textContent = query ? '没有找到这个词。' : '还没有保存的词。试着输入并确认一个短词，或在上方手动添加。'; $('entries').append(empty); }
  for (const item of state.blocked) {
    const row = document.createElement('div'); row.className = 'entry'; const title = document.createElement('strong'); title.textContent = item.text;
    row.append(title,button('恢复推荐',()=>change({action:'unblock',text:item.text}, '已恢复推荐。'))); $('blocked').append(row);
  }
  if (!state.blocked.length) { const empty = document.createElement('p'); empty.className='empty'; empty.textContent='没有屏蔽的词。'; $('blocked').append(empty); }
}
$('add-form').addEventListener('submit', async event => { event.preventDefault(); await change({action:'remember',text:$('word').value.trim(),input:$('reading').value.trim()}, '已保存到这台 Mac 的本地词库。'); });
$('block-form').addEventListener('submit', async event => { event.preventDefault(); await change({action:'block',text:$('blocked-word').value.trim()}, '已停止推荐这个词。'); });
$('learning').addEventListener('change', () => change({action:'learning',enabled:$('learning').checked}, $('learning').checked ? '已开启自动记忆。' : '已关闭自动记忆，已保存的词保留。'));
$('search').addEventListener('input',render);
$('clear').addEventListener('click', () => { if (confirm('清空所有手动保存和自动记忆的词？“不再推荐”列表会保留。')) change({action:'clear'}, '已清空本地个性化记忆，屏蔽列表保留。'); });
try { const response = await fetch('/api/state'); const result=await response.json(); if(!response.ok) throw new Error(result.error); state=result; render(); } catch(reason) { error(reason.message || '无法读取本地词库。'); }
