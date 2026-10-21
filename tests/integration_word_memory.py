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
import rime_api as api
from integration_rime import enter, select_first, find_squirrel


def check(condition, description):
    if not condition:
        raise AssertionError(description)
    print('PASS', description, flush=True)


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
    with tempfile.TemporaryDirectory(prefix='her-memory-integration-') as temporary:
        user = Path(temporary).resolve() / 'userdata'
        shutil.copytree(ROOT / 'rime', user, ignore=shutil.ignore_patterns('build', '.DS_Store'))
        for phase in ['exercise', 'restart']:
            subprocess.run([sys.executable, str(Path(__file__).resolve()), '--app', str(args.app),
                            '--worker', phase, '--user', str(user)], check=True)
    print('Memory lifecycle checks passed; no live Rime userdata opened.')


if __name__ == '__main__':
    main()
