#!/usr/bin/env python3
"""Local Rime word memory manager. Binds loopback; never reads chat context."""
import argparse
from contextlib import contextmanager
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import stat
import tempfile
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / 'web' / 'memory'
HEADER = 'HER_WORD_MEMORY\t1'
LIMIT = 2000
ASSETS = {'/': ('index.html', 'text/html'), '/memory.css': ('memory.css', 'text/css'),
          '/memory.mjs': ('memory.mjs', 'text/javascript')}


def fold(text):
    return text.translate(str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'))


def word(text):
    if (not isinstance(text, str) or not 1 <= len(text) <= 32 or len(text.encode('utf-8')) > 128
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in text)
            or any(c in text for c in '/:@，。？！；、（）【】')):
        raise ValueError('词条限 1–32 字，不含空白、网址、邮箱或句子标点。')
    return text


def reading(text):
    if not isinstance(text, str):
        raise ValueError('请输入拼音或英文缩写。')
    value = fold(text).replace(' ', '').replace("'", '')
    if not re.fullmatch('[a-z]{1,128}', value):
        raise ValueError('输入码请使用英文字母，可填完整拼音或自选缩写。')
    return value


def blocked(text, terms):
    lowered = fold(text)
    for term in terms:
        term = fold(term)
        if term.isascii():
            if re.search(r'(?<![a-z0-9_])' + re.escape(term) + r'(?![a-z0-9_])', lowered):
                return True
        elif term in lowered:
            return True
    return False


def integer(value):
    if not re.fullmatch(r'[0-9]{1,12}', value):
        raise ValueError('本地词库时间或计数格式错误，未覆盖原文件。')
    return int(value)


def lines(path):
    if path.is_symlink():
        raise ValueError('本地词库文件不能是符号链接。')
    if not path.exists():
        return []
    if path.stat().st_size > 2_000_000:
        raise ValueError('本地词库文件过大，未覆盖原文件。')
    text = path.read_text(encoding='utf-8')
    all_lines = text.splitlines()
    if not all_lines or all_lines[0] != HEADER or len(all_lines) > LIMIT * 4 + 3:
        raise ValueError('本地词库文件格式错误，未覆盖原文件。')
    return [line.split('\t') for line in all_lines[1:] if line]


def empty_policy():
    return {'learning': True, 'clear_before': 0, 'manual': {}, 'blocked': {}, 'forgotten': {}}


def read_policy(path):
    result = empty_policy()
    seen = set()
    for row in lines(path):
        identity = tuple(row[:2])
        if row[0] == 'S' and len(row) == 3 and row[1] == 'learning' and row[2] in ('0', '1'):
            result['learning'] = row[2] == '1'
        elif row[0] == 'S' and len(row) == 3 and row[1] == 'clear_before':
            result['clear_before'] = integer(row[2])
        elif row[0] == 'M' and len(row) == 4:
            code, text, timestamp = reading(row[1]), word(row[2]), integer(row[3])
            if code != row[1]:
                raise ValueError('本地输入码格式错误，未覆盖原文件。')
            identity = ('M', code, fold(text))
            result['manual'][identity[1:]] = {'input': code, 'text': text, 'lastUsed': timestamp}
        elif row[0] in ('B', 'F') and len(row) == 3:
            text, timestamp = word(row[1]), integer(row[2])
            identity = (row[0], fold(text))
            target = 'blocked' if row[0] == 'B' else 'forgotten'
            result[target][fold(text)] = {'text': text, 'lastUsed': timestamp}
        else:
            raise ValueError('本地词库规则格式错误，未覆盖原文件。')
        if identity in seen:
            raise ValueError('本地词库有重复规则，未覆盖原文件。')
        seen.add(identity)
        if any(len(result[key]) > LIMIT for key in ('manual', 'blocked', 'forgotten')):
            raise ValueError('本地词库单类记录超过 2000 项。')
    return result


def read_learned(path):
    result = {}
    for row in lines(path):
        if len(row) != 5 or row[0] != 'L':
            raise ValueError('学习记录格式错误，未覆盖原文件。')
        code, text = reading(row[1]), word(row[2])
        if code != row[1]:
            raise ValueError('学习记录的输入码格式错误。')
        count, timestamp = integer(row[3]), integer(row[4])
        if not 1 <= count <= 1_000_000:
            raise ValueError('学习记录计数异常。')
        identity = (code, fold(text))
        if identity in result:
            raise ValueError('学习记录含重复词条。')
        result[identity] = {'input': code, 'text': text, 'count': count, 'lastUsed': timestamp}
        if len(result) > LIMIT:
            raise ValueError('学习记录超过 2000 项。')
    return result


def write_policy(path, policy):
    output = [HEADER, 'S\tlearning\t' + str(int(policy['learning'])),
              'S\tclear_before\t' + str(policy['clear_before'])]
    for item in sorted(policy['manual'].values(), key=lambda x: (x['input'], x['text'])):
        output.append('M\t{input}\t{text}\t{lastUsed}'.format(**item))
    for kind, key in [('B', 'blocked'), ('F', 'forgotten')]:
        for item in sorted(policy[key].values(), key=lambda x: x['text']):
            output.append(kind + '\t{text}\t{lastUsed}'.format(**item))
    descriptor, name = tempfile.mkstemp(prefix='.her-memory-policy-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as stream:
            os.chmod(temporary, 0o600)
            stream.write('\n'.join(output) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class MemoryStore:
    def __init__(self, directory):
        self.directory = Path(directory).expanduser().absolute()
        if '..' in self.directory.parts:
            raise ValueError('本地词库目录不接受 .. 路径。')
        for parent in list(reversed(self.directory.parents)) + [self.directory]:
            if parent.is_symlink():
                raise ValueError('本地词库目录不能经过符号链接。')
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        information = self.directory.stat()
        if not stat.S_ISDIR(information.st_mode) or information.st_uid != os.getuid():
            raise ValueError('本地词库目录必须属于当前用户。')
        # Lua writes through atomic rename, so its parent protects every version
        # of the learned file, including the short-lived staging file.
        self.directory.chmod(0o700)
        self.policy_path = self.directory / 'her_memory_policy.tsv'
        self.learned_path = self.directory / 'her_memory_learned.tsv'

    @contextmanager
    def transaction(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        lock = self.directory / 'her_memory_policy.lock'
        descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield read_policy(self.policy_path)
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def state(self):
        # A replace is atomic; learned.tsv is owned exclusively by Rime/Lua.
        policy = read_policy(self.policy_path)
        learned = read_learned(self.learned_path)
        visible = {}
        for identity, item in learned.items():
            cutoff = max(policy['clear_before'], policy['forgotten'].get(fold(item['text']), {}).get('lastUsed', 0))
            if item['lastUsed'] > cutoff and not blocked(item['text'], policy['blocked']):
                visible[identity] = dict(item, manual=False)
        for identity, item in policy['manual'].items():
            if not blocked(item['text'], policy['blocked']):
                visible[identity] = dict(item, count=1, manual=True)
        entries = sorted(visible.values(), key=lambda x: (-x['lastUsed'], x['text'], x['input']))
        return {'entries': entries, 'blocked': sorted(policy['blocked'].values(), key=lambda x: x['text']),
                'learning': policy['learning'], 'directory': str(self.directory),
                'note': '只记录本输入法确认的短词；英文西文模式不会自动记忆，可手动添加英文与缩写。忘记会撤销个性化记忆，基础词典仍可能有该词；不想再看到时请选择“不再推荐”。'}

    def mutate(self, action, text=None, input=None, enabled=None):
        now = int(time.time())
        with self.transaction() as policy:
            learned = read_learned(self.learned_path)  # finish preflight before any write
            def forget_record(value):
                folded = fold(value)
                cutoff = max([now, policy['forgotten'].get(folded, {}).get('lastUsed', 0)] +
                             [item['lastUsed'] for item in learned.values() if fold(item['text']) == folded])
                policy['forgotten'][folded] = {'text': value, 'lastUsed': cutoff}
            if action == 'learning':
                if not isinstance(enabled, bool):
                    raise ValueError('自动记忆开关必须为布尔值。')
                policy['learning'] = enabled
            elif action == 'clear':
                policy['manual'].clear()
                policy['forgotten'].clear()
                policy['clear_before'] = max([now, policy['clear_before']] + [item['lastUsed'] for item in learned.values()])
            elif action in ('remember', 'forget', 'block', 'unblock'):
                text = word(text)
                folded = fold(text)
                if action in ('remember', 'forget', 'block'):
                    if action == 'block':
                        affected = [item['text'] for item in list(policy['manual'].values()) + list(learned.values())
                                    if blocked(item['text'], [text])]
                        for affected_text in affected:
                            forget_record(affected_text)
                        policy['manual'] = {k: v for k, v in policy['manual'].items() if not blocked(v['text'], [text])}
                    else:
                        policy['manual'] = {k: v for k, v in policy['manual'].items() if fold(v['text']) != folded}
                if action == 'remember':
                    if blocked(text, policy['blocked']):
                        raise ValueError('这个词已设为不再推荐，请先在屏蔽列表恢复。')
                    code = reading(input)
                    policy['manual'][(code, folded)] = {'input': code, 'text': text, 'lastUsed': now}
                elif action in ('forget', 'block'):
                    forget_record(text)
                    if action == 'block':
                        policy['blocked'][folded] = {'text': text, 'lastUsed': now}
                else:
                    policy['blocked'].pop(folded, None)
            else:
                raise ValueError('不支持的操作。')
            for key in ('manual', 'blocked', 'forgotten'):
                if len(policy[key]) > LIMIT:
                    raise ValueError('本地词库最多保存 2000 项，请先清理。')
            write_policy(self.policy_path, policy)
        return self.state()


def make_handler(store, token):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def allowed(self):
            origin = 'http://127.0.0.1:' + str(self.server.server_port)
            hosts = {'127.0.0.1:' + str(self.server.server_port), 'localhost:' + str(self.server.server_port)}
            return self.headers.get('Host') in hosts and self.headers.get('Origin') in (None, origin, origin.replace('127.0.0.1', 'localhost'))

        def reply(self, status, value, mime='application/json'):
            data = json.dumps(value, ensure_ascii=False).encode('utf-8') if mime == 'application/json' else value
            self.send_response(status)
            self.send_header('Content-Type', mime + '; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.allowed():
                return self.reply(403, {'error': '仅允许本机访问。'})
            path = urlsplit(self.path).path
            try:
                if path == '/api/state':
                    self.reply(200, dict(store.state(), token=token))
                elif path in ASSETS:
                    name, mime = ASSETS[path]
                    self.reply(200, (WEB / name).read_bytes(), mime)
                else:
                    self.reply(404, {'error': '页面不存在。'})
            except (OSError, ValueError, UnicodeError) as error:
                self.reply(500, {'error': str(error)})

        def do_POST(self):
            if not self.allowed() or self.headers.get('X-Her-Memory-Token') != token:
                self.close_connection = True
                return self.reply(403, {'error': '本地页面校验失败，请刷新页面。'})
            if self.path != '/api/change' or self.headers.get('Content-Type') != 'application/json':
                self.close_connection = True
                return self.reply(400, {'error': '请求格式错误。'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 4096:
                    raise ValueError('请求过大或为空。')
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict) or set(body) - {'action', 'text', 'input', 'enabled'}:
                    raise ValueError('请求字段错误。')
                result = store.mutate(**body)
                self.reply(200, dict(result, token=token))
            except (ValueError, TypeError, UnicodeError) as error:
                self.reply(400, {'error': str(error)})
            except OSError as error:
                self.reply(500, {'error': str(error)})

        def do_DELETE(self):
            self.reply(405, {'error': '不支持此请求。'})
        do_PUT = do_DELETE
        do_PATCH = do_DELETE
    return Handler


def create_server(directory, port=8767):
    return ThreadingHTTPServer(('127.0.0.1', port), make_handler(MemoryStore(directory), secrets.token_urlsafe(32)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path.home() / 'Library/Rime')
    parser.add_argument('--port', type=int, default=8767)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--list', action='store_true')
    actions.add_argument('--add', metavar='WORD')
    actions.add_argument('--forget', metavar='WORD')
    actions.add_argument('--block', metavar='WORD')
    actions.add_argument('--unblock', metavar='WORD')
    actions.add_argument('--clear', action='store_true')
    actions.add_argument('--learning', choices=['on', 'off'])
    parser.add_argument('--input', help='自定义完整拼音或缩写')
    args = parser.parse_args()
    store = MemoryStore(args.directory)
    try:
        if args.list:
            print(json.dumps(store.state(), ensure_ascii=False, indent=2))
            return 0
        if args.add or args.forget or args.block or args.unblock or args.clear or args.learning:
            if args.learning:
                result = store.mutate('learning', enabled=args.learning == 'on')
            elif args.clear:
                result = store.mutate('clear')
            else:
                action, value = next((name, value) for name, value in [('remember', args.add), ('forget', args.forget), ('block', args.block), ('unblock', args.unblock)] if value)
                result = store.mutate(action, text=value, input=args.input)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        server = create_server(args.directory, args.port)
        print('她说 · 本地词库：http://127.0.0.1:{}'.format(server.server_port), flush=True)
        print('仅本机访问；不读取聊天框，不上传词条。Ctrl+C 停止。', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
        return 0
    except (OSError, ValueError, UnicodeError) as error:
        print('本地词库操作未完成：' + str(error), file=__import__('sys').stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
