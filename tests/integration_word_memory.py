#!/usr/bin/env python3
"""Real librime memory lifecycle checks in disposable userdata, never live Rime."""
import argparse
import ctypes as C
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from manage_word_memory import MemoryStore, read_learned
from compile_packs import lua_quote
import rime_api as api
from integration_rime import enter, select_first, find_squirrel


def check(condition, description):
    if not condition:
        raise AssertionError(description)
    print('PASS', description, flush=True)


def check_lua_memory_contract(app):
    """Run the actual module in Squirrel's bundled Lua with disposable fixtures.

    The tiny context stub observes notifier attachment and commit ownership;
    real Rime candidate/commit integration follows in worker().
    """
    core = C.CDLL(str(app / 'Contents/Frameworks/librime.1.dylib'), mode=C.RTLD_GLOBAL)
    lua = C.CDLL(str(app / 'Contents/Frameworks/rime-plugins/librime-lua.dylib'), mode=C.RTLD_GLOBAL)
    lua.luaL_newstate.restype = C.c_void_p
    lua.luaL_openlibs.argtypes = [C.c_void_p]
    lua.luaL_loadstring.argtypes = [C.c_void_p, C.c_char_p]
    lua.luaL_loadstring.restype = C.c_int
    lua.lua_pcallk.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ssize_t, C.c_void_p]
    lua.lua_pcallk.restype = C.c_int
    lua.lua_tolstring.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_size_t)]
    lua.lua_tolstring.restype = C.c_char_p
    lua.lua_close.argtypes = [C.c_void_p]
    samples = [
        ('Ana', 'ANA', True), ('Ana', 'mañana', False), ('Ana', 'ñAna', False),
        ('sí', 'SÍ', True), ('sí', 'si\u0301', True), ('sí', 'así', False), ('sí', 'SI', False),
        ('ÁLEX', 'álex', True), ('álex', 'A\u0301LEX', True), ('álex', 'Álexa', False),
        ('man\u0303ana', 'MAÑANA', True), ('mañana', 'manana', False),
        ('pingüino', 'PINGU\u0308INO', True), ('café', 'CAFE\u0301', True),
        ('café', 'caféína', False), ('niño', 'nino', False), ('nino', 'niño', False),
        ('C++', 'áC++', False), ('C++', 'C++é', False), ('C++', '给C++留言', True),
        ('ana', 'Žana', False), ('Ana', 'ana_2', False), ('Ana', 'ana2', False),
        ('小ÁLEX', '和小A\u0301LEX一起', True), ('张三', '和张三一起', True),
        ('Ann', 'planning', False), ('C++', 'XcodeC++', False),
    ]
    with tempfile.TemporaryDirectory(prefix='her-lua-memory-contract-') as temporary:
        directory = Path(temporary).resolve()
        case_lua = ',\n'.join('{' + lua_quote(term) + ',' + lua_quote(text) + ','
                              + ('true' if expected else 'false') + '}' for term, text, expected in samples)
        script = ('package.path = ' + lua_quote(str(ROOT / 'rime/lua/?.lua')) + ' .. ";" .. package.path\n'
                  + 'local directory = ' + lua_quote(str(directory)) + '\n'
                  + 'local cases = {' + case_lua + '}\n' + r'''
local memory = require("her_memory")
local header = "HER_WORD_MEMORY\t1\n"
local policy_path, learned_path = directory .. "/her_memory_policy.tsv", directory .. "/her_memory_learned.tsv"
local function write(path, value) local f = assert(io.open(path, "w")); f:write(value); f:close() end
local function read(path) local f = assert(io.open(path, "r")); local value = f:read("*a"); f:close(); return value end
write(policy_path, header)
write(learned_path, header)
rime_api = { get_user_data_dir = function() return directory end }
local connections, callback = 0, nil
local selected, committed = {type = "her_memory", comment = ""}, "café"
local context = { input = "cafe", set_property = function() end,
  get_selected_candidate = function() return selected end,
  get_commit_text = function() return committed end,
  commit_notifier = {connect = function(_, fn)
    connections = connections + 1; callback = fn
    return {disconnect = function() end}
  end} }
local env = { engine = { context = context }, her_memory_readonly = true }
memory.init(env)
assert(connections == 0 and env.her_memory_connection == nil, "readonly attaches no commit notifier")
local stale = header .. "L\tcafe\tcafé\t1\t1\n"
write(learned_path, stale)
write(policy_path, header .. "B\tCAFÉ\t2\n")
memory.refresh(env)
assert(next(env.her_memory_words) == nil, "readonly still filters blocked learned words")
assert(read(learned_path) == stale, "readonly never rewrites the Chinese learner file, even during purge")
write(learned_path, header)
for _, case in ipairs(cases) do
  write(policy_path, header .. "B\t" .. case[1] .. "\t1\n")
  memory.refresh(env)
  assert(memory.is_blocked(env, case[2]) == case[3], "Lua boundary mismatch: " .. case[1] .. " / " .. case[2])
end
assert(read(learned_path) == header, "readonly comparisons write no new learned words")
write(policy_path, header)
memory.refresh(env)
assert(not memory.is_blocked(env, "ÁLEX"), "unblock invalidates comparison forms")
local normal = { engine = { context = context } }
memory.init(normal)
assert(connections == 1 and callback, "Chinese memory still owns one notifier")
selected.type = "her_es_lookup"
callback(context)
assert(read(learned_path) == header, "Chinese Spanish lookup must not learn a pinyin-to-Spanish mapping")
selected.type, committed, context.input = "her_memory", "你好", "nihao"
callback(context)
assert(read(learned_path):find("L\tnihao\t你好\t1\t", 1, true), "ordinary confirmed Chinese still learns")
memory.fini(normal)
''')
        state = lua.luaL_newstate()
        if not state:
            raise RuntimeError('Could not allocate bundled Lua state')
        try:
            lua.luaL_openlibs(state)
            status = lua.luaL_loadstring(state, script.encode('utf-8'))
            if not status:
                status = lua.lua_pcallk(state, 0, 0, 0, 0, None)
            if status:
                raise AssertionError('Bundled Lua memory contract: ' + api.decode(lua.lua_tolstring(state, -1, None)))
        finally:
            lua.lua_close(state)
    print('Bundled Lua memory: {} boundary cases plus notifier ownership passed.'.format(len(samples)), flush=True)


def worker(app, user, phase):
    if user.resolve() == (Path.home() / 'Library/Rime').resolve():
        raise ValueError('Refusing live userdata')
    store = MemoryStore(user)
    engine = api.Rime(app, app / 'Contents/SharedSupport', user)
    engine.deploy()
    checks = 0
    def query(code, commit=False):
        sid = engine.session('her_words')
        try:
            enter(engine, sid, code)
            texts, truncated = engine.candidates(sid, 10000)
            if truncated:
                raise AssertionError('Candidate enumeration truncated: ' + code)
            selected = select_first(engine, sid)[0] if commit else ''
            return texts, selected
        finally:
            engine.destroy(sid)
    try:
        if phase == 'exercise':
            query('zhangsan')
            check(store.state()['entries'] == [], 'composing or canceling does not learn')
            texts, selected = query('zhangsan', True)
            check(selected == '张三', 'real Chinese name is confirmed by Space')
            check(any(w['text'] == '张三' for w in store.state()['entries']), 'commit notifier persists only confirmed name')
            store.mutate('remember', text='林知夏', input='lzx')
            texts, selected = query('lzx', True)
            check(texts[0] == '林知夏' and selected == '林知夏', 'manual name and abbreviation select and commit')
            store.mutate('remember', text='GitHub', input='gh')
            texts, selected = query('gh', True)
            check(texts[0] == 'GitHub' and selected == 'GitHub', 'English term and abbreviation select and commit')
            store.mutate('forget', text='GitHub')
            check('GitHub' not in query('gh')[0], 'forget removes managed English mapping before next selection')
            check(not any(w['text'] == 'GitHub' for w in read_learned(store.learned_path).values()), 'Lua physically purges forgotten managed row on next composition')
            store.mutate('block', text='张三')
            for code in ['zhangsan', 'zs', 'zhangsannihao']:
                texts, _ = query(code)
                check(all('张三' not in text for text in texts), 'blocked Chinese name absent from all candidates: ' + code)
            check(not any(w['text'] == '张三' for w in read_learned(store.learned_path).values()), 'blocked name not retained by managed learner')
            store.mutate('unblock', text='张三')
            check('张三' in query('zhangsan')[0], 'restore permits base dictionary recommendation')
            store.mutate('remember', text='planning', input='pl')
            store.mutate('remember', text='XcodeC++', input='xc')
            store.mutate('remember', text='C++foo', input='cf')
            store.mutate('block', text='Ann')
            store.mutate('block', text='C++')
            check(query('pl')[0][0] == 'planning', 'Ann block leaves planning unchanged')
            check(query('xc')[0][0] == 'XcodeC++', 'ASCII symbol block respects preceding word boundary')
            check(query('cf')[0][0] == 'C++foo', 'ASCII symbol block respects following word boundary')
            query('nihao', True)
            check(any(w['text'] == '你好' for w in store.state()['entries']), 'ordinary confirmed word remains available for restart')
            store.mutate('learning', enabled=False)
            query('xiexie', True)
            check(not any(w['input'] == 'xiexie' for w in store.state()['entries']), 'disabled managed learning writes no new word')
            store.mutate('learning', enabled=True)
            check(query('ta')[0][:2] == ['她', '他'], 'female pronoun is first while male pronoun remains near front')
            store.mutate('remember', text='他们', input='tamen')
            check(query('tamen')[0][:2] == ['她们', '他们'], 'remembered male plural does not displace female default')
            store.mutate('forget', text='他们')
            store.mutate('block', text='他')
            check('他' not in query('ta')[0] and query('ta')[0][0] == '她', 'private male pronoun block remains effective')
            store.mutate('unblock', text='他')
            check(query('ta')[0][:2] == ['她', '他'], 'restoring male pronoun restores selectable alternative')
            store.mutate('block', text='她')
            check('她' not in query('ta')[0] and query('ta')[0][0] == '他', 'blocking female default leaves male alternative available')
            store.mutate('unblock', text='她')
            store.mutate('remember', text='情緒價值', input='qx')
            sid = engine.session('her_words')
            def in_same_session(code):
                engine.bind('clear_composition', None, C.c_size_t)(sid)
                committed, failures = enter(engine, sid, code)
                if committed or failures:
                    raise AssertionError('Unexpected persistent-session input result')
                texts, truncated = engine.candidates(sid, 10000)
                if truncated:
                    raise AssertionError('Persistent-session candidates truncated')
                return texts
            try:
                check('情緒價值' in in_same_session('qx'), 'manual traditional word is available before blocking')
                store.mutate('block', text='情绪')
                check('情緒價值' not in in_same_session('qx'), 'simplified block hides traditional manual word in existing session')
                store.mutate('unblock', text='情绪')
                check('情緒價值' in in_same_session('qx'), 'unblock invalidates normalized suppression in existing session')
                store.mutate('block', text='情緒')
                check('情绪价值' not in in_same_session('qingxujiazhi'), 'traditional block hides simplified dictionary and public word in existing session')
                store.mutate('unblock', text='情緒')
                check('情绪价值' in in_same_session('qingxujiazhi'), 'restored script variant returns in existing session')
            finally:
                engine.destroy(sid)
                store.mutate('forget', text='情緒價值')
            policy = store.policy_path.read_bytes()
            store.policy_path.write_text('broken')
            check(query('zhangsan')[0] == [], 'corrupt policy fails closed for a new engine session')
            store.policy_path.write_bytes(policy)
            original = store.learned_path.read_bytes()
            store.learned_path.write_text('broken learned file')
            query('mama', True)
            check(store.learned_path.read_text() == 'broken learned file', 'corrupt learned file is never silently overwritten')
            store.learned_path.write_bytes(original)
        else:
            texts, _ = query('nihao')
            check(texts[0] == '你好', 'learned word recommendation survives process restart')
            check(any(w['text'] == '你好' and not w['manual'] for w in store.state()['entries']), 'restart reads durable learned record')
            check(query('lzx')[0][0] == '林知夏', 'manual name survives process restart')
            store.mutate('remember', text='王五', input='ww')
            store.mutate('block', text='王五')
            store.mutate('clear')
            check(store.state()['entries'] == [], 'clear removes all managed records')
            query('nihao')
            check(read_learned(store.learned_path) == {}, 'Lua purges cleared learned rows on next composition')
            check('王五' not in query('wangwu')[0], 'clear retains never-recommend policy')
            store.mutate('remember', text='Node.js', input='node')
            check(query('node')[0][0] == 'Node.js', 'new manual entries work even in same second as clear')
    finally:
        engine.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=find_squirrel())
    parser.add_argument('--worker', choices=['exercise', 'restart'])
    parser.add_argument('--user', type=Path)
    args = parser.parse_args()
    if args.app is None:
        parser.error('Squirrel.app required')
    if args.worker:
        return worker(args.app, args.user, args.worker)
    check_lua_memory_contract(args.app)
    with tempfile.TemporaryDirectory(prefix='her-memory-integration-') as temporary:
        user = Path(temporary).resolve() / 'userdata'
        shutil.copytree(ROOT / 'rime', user, ignore=shutil.ignore_patterns('build', '.DS_Store'))
        for phase in ['exercise', 'restart']:
            subprocess.run([sys.executable, str(Path(__file__).resolve()), '--app', str(args.app),
                            '--worker', phase, '--user', str(user)], check=True)
    print('Memory lifecycle checks passed; no live Rime userdata opened.')


if __name__ == '__main__':
    main()
