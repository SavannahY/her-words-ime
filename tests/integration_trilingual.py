#!/usr/bin/env python3
"""Exercise three Mac schemas in real librime, exclusively in temporary userdata."""
import argparse
import ctypes as C
from pathlib import Path
import shutil
import sys
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from manage_word_memory import MemoryStore
from compile_spanish_learning import compile_data, load_spanish_learning
from install_macos import plan_user_options
import rime_api as api
from integration_rime import enumerate_candidates, find_squirrel, select_text, source_hashes


def exercise(app, user):
    engine = api.Rime(app, app / 'Contents/SharedSupport', user)
    engine.deploy()
    checks = 0

    def check(condition, message):
        nonlocal checks
        if not condition:
            raise AssertionError(message)
        checks += 1
        print('PASS', message, flush=True)

    def option(sid, name, enabled):
        engine.bind('set_option', None, C.c_size_t, C.c_char_p, C.c_int)(sid, name.encode(), enabled)

    def key(sid, code, modifier=0):
        return bool(engine.bind('process_key', C.c_int, C.c_size_t, C.c_int, C.c_int)(sid, code, modifier))

    def type_text(sid, text):
        output = ''
        for char in text:
            handled = engine.key(sid, char)
            output += engine.commit(sid)
            if not handled:
                output += char  # What the host app receives from a rejected printable key.
        return output

    def candidates(sid):
        rows, truncated = enumerate_candidates(engine, sid, 10000)
        if truncated:
            raise AssertionError('Unexpected candidate truncation')
        return rows

    def clear(sid):
        engine.bind('clear_composition', None, C.c_size_t)(sid)
        engine.commit(sid)

    def menu_choose(sid, label):
        check(key(sid, ord('`'), 4), 'Control+grave opens real schema/options menu')
        rows = candidates(sid)
        matches = [index for index, row in enumerate(rows) if row['text'] == label]
        if not matches:
            # Rime abbreviates a folded settings row (中／半／汉／…); selecting
            # it expands the actual switch labels without changing a setting.
            folded = [index for index, row in enumerate(rows) if not row['text'].startswith('她说 ·')]
            if len(folded) == 1:
                engine.bind('select_candidate', C.c_int, C.c_size_t, C.c_size_t)(sid, folded[0])
                rows = candidates(sid)
                matches = [index for index, row in enumerate(rows) if row['text'] == label]
        check(len(matches) == 1, 'menu contains requested schema or switch: ' + label)
        check(bool(engine.bind('select_candidate', C.c_int, C.c_size_t, C.c_size_t)(sid, matches[0])),
              'menu selection applies: ' + label)

    store = MemoryStore(user)
    material = compile_data(load_spanish_learning()[0])
    try:
        sid = engine.session('her_english')
        try:
            for sample in ['Hello, GitHub! 123; nino', 'Español: sí, ñ, ¿hola?']:
                check(type_text(sid, sample) == sample and not engine.context(sid)['preedit'],
                      'English passes exact letters, digits, punctuation and Latin text: ' + sample)
            for code, modifier in [(0xffe1, 0), (0xffe5, 0), (ord('c'), 1 << 26), (ord('v'), 1 << 26)]:
                check(not key(sid, code, modifier), 'English leaves modifier/Command key to host: ' + str(code))
        finally:
            engine.destroy(sid)

        sid = engine.session('her_spanish')
        try:
            check(bool(engine.bind('get_option', C.c_int, C.c_size_t, C.c_char_p)(sid, b'her_es_hints')),
                  'first-use installer setting enables Spanish glosses')
            option(sid, 'her_es_hints', True)
            for raw, expected in [
                ('Hola mundo ', 'Hola mundo '),
                ('si tu el ano ', 'si tu el ano '),
                (';?C;omo est;as? ', '¿Cómo estás? '),
                (';!Espa;nol! ', '¡Español! '),
                (';a;e;i;o;u;n;v ', 'áéíóúñü '),
                (';A;E;I;O;U;N;V ', 'ÁÉÍÓÚÑÜ '),
                ('ping;;pong code-123@example.com ', 'ping;pong code-123@example.com '),
                ('mañana sí über ', 'mañana sí über '),
                ('abcdefghijklmnopqrstuvwxyzzzz ', 'abcdefghijklmnopqrstuvwxyzzzz '),
            ]:
                check(type_text(sid, raw) == expected, 'Spanish raw typing, accents and real spaces: ' + raw)
                check(not engine.context(sid)['preedit'], 'word boundary leaves no uncommitted text')

            for word in ['si', 'tu', 'el', 'ano']:
                type_text(sid, word)
                check(candidates(sid)[0]['text'] == word, 'ambiguous spelling stays first: ' + word)
                clear(sid)

            for word in material['entries']:
                type_text(sid, word['input'])
                rows = candidates(sid)
                check(any(row['text'] == word['text'] and word['meaning'] in row['comment'] for row in rows),
                      'curated Spanish form and gloss are reachable: ' + word['id'])
                clear(sid)

            type_text(sid, ';n')
            check(api.decode(engine.bind('get_input', C.c_char_p, C.c_size_t)(sid)) == 'ñ',
                  'front-end focus-loss flush sees actual ñ rather than shortcut code')
            key(sid, 0xff08)
            check(not engine.context(sid)['preedit'], 'Backspace deletes the whole explicitly entered accent')

            type_text(sid, 'hola')
            rows = candidates(sid)
            check(rows[0]['text'] == 'hola' and '你好' in rows[0]['comment'], 'gloss appears beside raw Spanish word')
            option(sid, 'her_es_hints', False)
            clear(sid)
            type_text(sid, 'hola')
            check(all(not row['comment'] for row in candidates(sid)), 'gloss switch removes every Chinese annotation')
            check(type_text(sid, ' ') == 'hola ', 'hidden annotations never enter committed text')
            option(sid, 'her_es_hints', True)

            type_text(sid, 'gracias')
            rows = candidates(sid)
            check(len(rows) > 1, 'Spanish phrase alternatives are available')
            check(key(sid, 0xff09), 'Tab selects an explicit alternative')
            check(type_text(sid, ' ') == rows[1]['text'] + ' ', 'selected phrase commits Spanish only plus real space')

            type_text(sid, 'mañana')
            check(key(sid, 0xff08), 'Backspace edits composed Latin text')
            check(type_text(sid, ' ') == 'mañan ', 'Backspace removes one letter')
            type_text(sid, 'ñ')
            key(sid, 0xff08)
            check(not engine.context(sid)['preedit'], 'Backspace removes a UTF-8 ñ without corruption')
            type_text(sid, 'cancelar')
            check(key(sid, 0xff1b) and not engine.context(sid)['preedit'] and not engine.commit(sid),
                  'Escape cancels a word without committing')
            for navigation in [0xff51, 0xff53, 0xff50, 0xff57, 0xff0d]:
                type_text(sid, 'hola')
                check(not key(sid, navigation) and engine.commit(sid) == 'hola',
                      'navigation/Return commits pending word then reaches host: ' + str(navigation))
            type_text(sid, 'copiar')
            check(not key(sid, ord('c'), 1 << 26) and engine.commit(sid) == 'copiar',
                  'Command shortcut commits pending word and reaches host')

            menu_choose(sid, '显示西语释义')
            check(not engine.bind('get_option', C.c_int, C.c_size_t, C.c_char_p)(sid, b'her_es_hints'),
                  'real options menu disables Spanish gloss')
            menu_choose(sid, '她说 · English')
            check(type_text(sid, 'English menu switch ') == 'English menu switch ',
                  'schema menu switches to raw English typing')
            menu_choose(sid, '她说 · 女性优先全拼')
            menu_choose(sid, '关闭中文查西语')
            check(bool(engine.bind('get_option', C.c_int, C.c_size_t, C.c_char_p)(sid, b'her_es_lookup')),
                  'Chinese menu enables lookup independently')
            menu_choose(sid, '她说 · Español 西班牙语')
            # Rime flushes changed options when selecting a schema.
            saved = yaml.safe_load((user / 'user.yaml').read_text())['var']['option']
            check(saved['her_es_hints'] is False and saved['her_es_lookup'] is True,
                  'independent switch choices are saved to disk across schema changes')
            check(not engine.bind('get_option', C.c_int, C.c_size_t, C.c_char_p)(sid, b'her_es_hints'),
                  'disabled gloss survives switching through English and Chinese')
            menu_choose(sid, '隐藏西语释义')
            menu_choose(sid, '她说 · 女性优先全拼')
            menu_choose(sid, '开启中文查西语')
            menu_choose(sid, '她说 · Español 西班牙语')
        finally:
            engine.destroy(sid)

        learned = user / 'her_memory_learned.tsv'
        check(not learned.exists(), 'Spanish typing and choosing phrases never writes Chinese learned memory')

        sid = engine.session('her_words')
        try:
            check(not engine.bind('get_option', C.c_int, C.c_size_t, C.c_char_p)(sid, b'her_es_lookup'),
                  'first-use installer setting leaves Chinese lookup disabled')
            option(sid, 'her_es_lookup', False)
            type_text(sid, 'nihao')
            baseline = candidates(sid)
            check(not any(row['text'] == 'Hola.' for row in baseline), 'Chinese lookup is independently disabled')
            first = baseline[0]['text']
            clear(sid)
            option(sid, 'her_es_lookup', True)
            type_text(sid, 'nihao')
            rows = candidates(sid)
            check(rows[0]['text'] == first and any(row['text'] == 'Hola.' for row in rows),
                  'Chinese pinyin lookup adds Spanish without displacing normal Chinese first')
            selected, failures = select_text(engine, sid, 'Hola.', [r['text'] for r in rows])
            check(selected == 'Hola.' and not failures, 'Chinese lookup commits only selected Spanish text')
            check(not learned.exists(), 'Chinese pinyin query is not saved as spelling of Spanish phrase')
            for word in material['chinese']:
                clear(sid)
                type_text(sid, word['input'])
                rows = candidates(sid)
                selected, failures = select_text(engine, sid, word['text'], [row['text'] for row in rows])
                check(selected == word['text'] and not failures,
                      'Chinese query selects exact Spanish form: ' + word['query'])
            check(not learned.exists(), 'all curated Chinese queries leave Chinese learned memory untouched')
            type_text(sid, 'ta')
            check([row['text'] for row in candidates(sid)][:2] == ['她', '他'], 'Chinese retains female first and selectable male pronoun')
            clear(sid)
            type_text(sid, 'nihao')
            option(sid, 'her_es_lookup', False)
            clear(sid)
            type_text(sid, 'nihao')
            check(not any(row['text'] == 'Hola.' for row in candidates(sid)), 'lookup can be turned off again')
        finally:
            engine.destroy(sid)

        store.mutate('block', text='Hola')
        sid = engine.session('her_spanish')
        try:
            type_text(sid, 'hola')
            check(not candidates(sid), 'Spanish suppression applies to raw and phrase alternatives')
            check(type_text(sid, ' ') == ' ', 'blocked raw spelling cannot bypass suppression at commit')
        finally:
            engine.destroy(sid)
        sid = engine.session('her_words')
        try:
            option(sid, 'her_es_lookup', True)
            type_text(sid, 'nihao')
            check(not any(row['text'] == 'Hola.' for row in candidates(sid)), 'same suppression applies to Chinese-to-Spanish lookup')
        finally:
            engine.destroy(sid)
        store.mutate('unblock', text='Hola')
        store.mutate('block', text='si')
        sid = engine.session('her_spanish')
        try:
            type_text(sid, 'si')
            check(not candidates(sid) and type_text(sid, ' ') == ' ',
                  'suppressed raw si cannot promote accented sí or a phrase to default')
        finally:
            engine.destroy(sid)
        store.mutate('unblock', text='si')
        store.mutate('block', text='你好')
        sid = engine.session('her_spanish')
        try:
            option(sid, 'her_es_hints', True)
            type_text(sid, 'hola')
            rows = candidates(sid)
            check(rows[0]['text'] == 'hola' and not rows[0]['comment'] and type_text(sid, ' ') == 'hola ',
                  'suppressed gloss disappears while safe original spelling remains first')
        finally:
            engine.destroy(sid)
    finally:
        engine.close()
    print(f'Trilingual integration: {checks} checks passed; no live userdata opened.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=find_squirrel())
    args = parser.parse_args()
    if args.app is None:
        parser.error('Squirrel.app required')
    before = source_hashes(ROOT / 'rime')
    with tempfile.TemporaryDirectory(prefix='her-trilingual-') as temporary:
        user = Path(temporary).resolve() / 'userdata'
        shutil.copytree(ROOT / 'rime', user, ignore=shutil.ignore_patterns('build', '.DS_Store'))
        (user / 'user.yaml').write_text(plan_user_options(''), encoding='utf-8')
        exercise(args.app, user)
    if source_hashes(ROOT / 'rime') != before:
        raise AssertionError('Repository Rime files changed during integration')


if __name__ == '__main__':
    main()
