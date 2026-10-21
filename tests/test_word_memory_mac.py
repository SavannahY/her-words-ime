"""Local memory ownership, deletion and loopback mutation boundary tests."""
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import manage_word_memory as memory


class StoreChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve() / 'Rime'
        self.store = memory.MemoryStore(self.directory)

    def learned(self, content='L\tzhangsan\t张三\t4\t100\n'):
        self.store.learned_path.write_text(memory.HEADER + '\n' + content)

    def test_private_directory_and_atomic_policy_permissions(self):
        self.store.mutate('remember', text='GitHub', input='gh')
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.store.policy_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.store.state()['entries'][0]['text'], 'GitHub')

    def test_remember_edit_and_normalization_preserve_other_words(self):
        self.store.mutate('remember', text='林知夏', input="lin zhi'xia")
        self.store.mutate('remember', text='GitHub', input='GH')
        self.store.mutate('remember', text='GitHub', input='github')
        self.assertEqual({(w['text'], w['input']) for w in self.store.state()['entries']},
                         {('林知夏', 'linzhixia'), ('GitHub', 'github')})

    def test_forget_cutoff_hides_old_learning_without_touching_lua_file(self):
        self.learned()
        original = self.store.learned_path.read_bytes()
        with patch.object(memory.time, 'time', return_value=101):
            self.store.mutate('forget', text='张三')
        self.assertEqual(self.store.state()['entries'], [])
        self.assertEqual(self.store.learned_path.read_bytes(), original)
        self.learned('L\tzhangsan\t张三\t1\t102\n')
        self.assertEqual(self.store.state()['entries'][0]['text'], '张三')

    def test_block_disables_relearning_and_unblock_is_explicit(self):
        self.learned()
        self.store.mutate('block', text='张三')
        self.learned('L\tzhangsan\t张三\t10\t9999999999\n')
        self.assertEqual(self.store.state()['entries'], [])
        with self.assertRaises(ValueError):
            self.store.mutate('remember', text='张三', input='zs')
        self.store.mutate('unblock', text='张三')
        self.store.mutate('remember', text='张三', input='zs')
        self.assertTrue(any(w['input'] == 'zs' for w in self.store.state()['entries']))

    def test_clear_preserves_blocks_and_ignores_old_learned_rows(self):
        self.learned()
        self.store.mutate('remember', text='GitHub', input='gh')
        self.store.mutate('block', text='王五')
        with patch.object(memory.time, 'time', return_value=101):
            self.store.mutate('clear')
        self.assertEqual(self.store.state()['entries'], [])
        self.assertEqual([w['text'] for w in self.store.state()['blocked']], ['王五'])

    def test_ascii_boundary_and_chinese_compounds(self):
        self.assertTrue(memory.blocked('Ann', ['ann']))
        self.assertTrue(memory.blocked('hello ANN!', ['Ann']))
        self.assertFalse(memory.blocked('planning', ['Ann']))
        self.assertFalse(memory.blocked('ann_2', ['Ann']))
        self.assertTrue(memory.blocked('我和张三一起', ['张三']))
        self.assertTrue(memory.blocked('C++', ['C++']))
        self.assertFalse(memory.blocked('XcodeC++', ['C++']))
        self.assertFalse(memory.blocked('C++foo', ['C++']))

    def test_manual_remember_keeps_forget_cutoff_for_old_aliases(self):
        self.learned()
        with patch.object(memory.time, 'time', return_value=101):
            self.store.mutate('forget', text='张三')
            self.store.mutate('remember', text='张三', input='zs')
        self.assertEqual([(w['text'], w['input']) for w in self.store.state()['entries']], [('张三', 'zs')])

    def test_forget_and_clear_handle_clock_rollback(self):
        self.learned('L\tzhangsan\t张三\t4\t9999999999\n')
        self.store.mutate('forget', text='张三')
        self.assertEqual(self.store.state()['entries'], [])
        self.store.mutate('clear')
        self.assertEqual(self.store.state()['entries'], [])

    def test_block_compound_does_not_revive_after_immediate_restore(self):
        self.learned('L\tans\tAnn-Smith\t4\t9999999999\n')
        self.store.mutate('remember', text='Ann-Smith', input='as')
        self.store.mutate('block', text='Ann')
        self.store.mutate('unblock', text='Ann')
        self.assertEqual(self.store.state()['entries'], [])

    def test_invalid_data_or_control_content_never_overwrites(self):
        for bad in ['two words', 'http://a', 'a@b', '张\n三', '名字。', 'a' * 33, '甲' * 33]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.store.mutate('remember', text=bad, input='abc')
        self.store.policy_path.write_text('broken')
        with self.assertRaises(ValueError):
            self.store.mutate('block', text='张三')
        self.assertEqual(self.store.policy_path.read_text(), 'broken')

    def test_corrupt_learning_fails_preflight_before_policy_mutation(self):
        self.store.learned_path.write_text('not TSV')
        with self.assertRaises(ValueError):
            self.store.mutate('learning', enabled=False)
        self.assertFalse(self.store.policy_path.exists())

    def test_learning_toggle_keeps_manual_words(self):
        self.store.mutate('learning', enabled=False)
        self.store.mutate('remember', text='Node.js', input='node')
        self.assertFalse(self.store.state()['learning'])
        self.assertEqual(self.store.state()['entries'][0]['text'], 'Node.js')

    def test_concurrent_writers_merge_under_shared_flock(self):
        def add(index):
            code = 'x' + chr(97 + index)
            self.store.mutate('remember', text='Word' + str(index), input=code)
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(add, range(20)))
        self.assertEqual(len(self.store.state()['entries']), 20)

    def test_symlink_directory_and_policy_rejected(self):
        linked = self.directory.parent / 'link'
        linked.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            memory.MemoryStore(linked)
        self.store.policy_path.symlink_to(self.directory / 'missing')
        with self.assertRaises(ValueError):
            self.store.mutate('block', text='张三')


class HTTPChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.server = memory.create_server(self.directory, 0)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        self.connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port)
        self.addCleanup(self.connection.close)
        self.origin = 'http://127.0.0.1:' + str(self.server.server_port)

    def request(self, method, path, body=None, headers=None):
        self.connection.request(method, path, body=body, headers=headers or {})
        response = self.connection.getresponse()
        data = response.read()
        return response.status, data

    def test_only_loopback_with_no_cors_and_safe_assets(self):
        self.assertEqual(self.server.server_address[0], '127.0.0.1')
        self.assertEqual(self.request('GET', '/')[0], 200)
        self.assertEqual(self.request('GET', '/../scripts/manage_word_memory.py')[0], 404)
        self.assertEqual(self.request('GET', '/api/state', headers={'Host': 'evil.example'})[0], 403)

    def test_foreign_origin_cannot_read_words_or_post(self):
        self.assertEqual(self.request('GET', '/api/state', headers={'Origin': 'https://evil.example'})[0], 403)
        self.assertEqual(self.request('POST', '/api/change', '{}', {'Origin': 'https://evil.example', 'Content-Type': 'application/json'})[0], 403)

    def test_valid_token_required_and_real_operation_roundtrips(self):
        status, data = self.request('GET', '/api/state')
        self.assertEqual(status, 200)
        token = json.loads(data)['token']
        payload = json.dumps({'action': 'remember', 'text': 'GitHub', 'input': 'gh'})
        self.assertEqual(self.request('POST', '/api/change', payload, {'Content-Type': 'application/json'})[0], 403)
        headers = {'Content-Type': 'application/json', 'X-Her-Memory-Token': token, 'Origin': self.origin}
        status, data = self.request('POST', '/api/change', payload, headers)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['entries'][0]['text'], 'GitHub')


if __name__ == '__main__':
    unittest.main()
