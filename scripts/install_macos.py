#!/usr/bin/env python3
"""Install only Her Words configuration, preserving existing Rime schemes."""
import argparse
import datetime
from dataclasses import dataclass
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys

try:
    import yaml
except ImportError as error:
    dependency_help = ('缺少 PyYAML。请先在项目虚拟环境运行：python -m pip install -r '
                       + str(Path(__file__).resolve().parents[1] / 'requirements.txt'))
    if __name__ == '__main__':
        print(dependency_help, file=sys.stderr)
        sys.exit(1)
    raise ImportError(dependency_help) from error

try:
    from .compile_packs import compile_project
    from .validate_packs import ValidationError, load_project
except ImportError:
    from compile_packs import compile_project
    from validate_packs import ValidationError, load_project

ROOT = Path(__file__).resolve().parents[1]
OWN_FILES = ['her_words.schema.yaml', 'her_pinyin.dict.yaml', 'her_words.dict.yaml',
             'lua/her_filter.lua', 'lua/her_rewrite_rules.lua']
TOUCHED_FILES = OWN_FILES + ['default.custom.yaml', 'squirrel.custom.yaml', 'user.yaml']


class UniqueKeySafeLoader(yaml.SafeLoader):
    """Retain safe YAML semantics while rejecting duplicate explicit keys."""

    def construct_document(self, node):
        # Inspect original nodes before SafeLoader flattens YAML merges. Legal
        # explicit overrides of merged values are not duplicate explicit keys.
        pending, visited = [node], set()
        while pending:
            current = pending.pop()
            if id(current) in visited:
                continue
            visited.add(id(current))
            if isinstance(current, yaml.nodes.SequenceNode):
                pending.extend(current.value)
            elif isinstance(current, yaml.nodes.MappingNode):
                explicit, merge_key = set(), object()
                for key_node, value_node in current.value:
                    if not isinstance(key_node, yaml.nodes.ScalarNode):
                        raise yaml.constructor.ConstructorError(
                            'while constructing a mapping', current.start_mark,
                            'unhashable YAML mapping key', key_node.start_mark)
                    key = (merge_key if key_node.tag == 'tag:yaml.org,2002:merge'
                           else self.construct_object(key_node))
                    if key in explicit:
                        raise yaml.constructor.ConstructorError(
                            'while constructing a mapping', current.start_mark,
                            'duplicate YAML key: {!r}'.format(key), key_node.start_mark)
                    explicit.add(key)
                    pending.append(value_node)
        return super().construct_document(node)


def load_custom_yaml(text):
    """Load a single mapping with SafeLoader; an empty document means {}."""
    loader = UniqueKeySafeLoader(text)
    try:
        node = loader.get_single_node()
        value = {} if node is None else loader.construct_document(node)
    except yaml.YAMLError as error:
        raise RuntimeError('default.custom.yaml 不是安全、有效且无重复键的 YAML：' + str(error)) from error
    finally:
        loader.dispose()
    if not isinstance(value, dict):
        raise RuntimeError('default.custom.yaml 顶层必须是映射。')
    return value


def plan_default_custom(text):
    """Return the patched document and selected Rime patch key, without writes."""
    document = load_custom_yaml(text)
    if 'patch' not in document:
        document['patch'] = {}
    patch = document['patch']
    if not isinstance(patch, dict):
        raise RuntimeError('default.custom.yaml 的 patch 必须是映射。')
    # YAML anchors can share mappings/lists with unrelated configuration keys.
    # Copy only what we edit so changing patch never edits an anchored default.
    patch = dict(patch)
    document['patch'] = patch
    lists = []
    for key in ('schema_list', 'schema_list/+'):
        if key not in patch:
            continue
        values = patch[key]
        if not isinstance(values, list):
            raise RuntimeError('patch/{} 必须是列表。'.format(key))
        for value in values:
            if (not isinstance(value, dict) or not isinstance(value.get('schema'), str)
                    or not value['schema'].strip()):
                raise RuntimeError('patch/{} 每一项必须含有非空 schema 名称。'.format(key))
        lists.append(values)
    key = 'schema_list' if 'schema_list' in patch else 'schema_list/+'
    # An existing append patch can already register her_words even when a full
    # list is also present. Avoid registering it twice, and remain idempotent.
    if not any(value['schema'] == 'her_words' for values in lists for value in values):
        patch[key] = list(patch.get(key, [])) + [{'schema': 'her_words'}]
    output = yaml.safe_dump(document, allow_unicode=True, sort_keys=False,
                            default_flow_style=False)
    return output, key


def absolute_target(path):
    """Keep lexical path components so resolving cannot conceal symlinks."""
    path = Path(path).expanduser()
    if '..' in path.parts:
        raise RuntimeError('目标路径请使用不含 .. 的明确路径。')
    return path if path.is_absolute() else Path.cwd() / path


def check_destination(path, directory=False):
    """Reject symlinks at the destination and every existing parent component."""
    path = absolute_target(path)
    parts = list(reversed(path.parents)) + [path]
    for current in parts:
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise RuntimeError('为避免改动链接目标，请先自行处理配置符号链接：' + str(current))
        is_directory = current != path or directory
        valid = stat.S_ISDIR(info.st_mode) if is_directory else stat.S_ISREG(info.st_mode)
        if not valid:
            raise RuntimeError('配置路径类型异常：' + str(current))
    return path


def check_target(target):
    target = check_destination(target, directory=True)
    for name in TOUCHED_FILES:
        check_destination(target / name)
    build = check_destination(target / 'build', directory=True)
    if build.exists():
        # The deployer writes existing build files as well as the top directory.
        for parent, directories, files in os.walk(build, followlinks=False):
            for name in directories:
                check_destination(Path(parent) / name, directory=True)
            for name in files:
                check_destination(Path(parent) / name)
    return target


@dataclass(frozen=True)
class InstallPlan:
    target: Path
    files: dict
    schema_patch: str


def prepare_plan(target, manifest, theme=False):
    """Validate and compile the complete installation before any target writes."""
    target = check_target(target)
    current = target / 'default.custom.yaml'
    try:
        original = current.read_text(encoding='utf-8') if current.exists() else ''
    except UnicodeError as error:
        raise RuntimeError('default.custom.yaml 必须是有效 UTF-8。') from error
    default_custom, schema_patch = plan_default_custom(original)
    project = load_project(manifest)
    files = {name: (ROOT / 'rime' / name).read_bytes() for name in OWN_FILES
             if name != 'lua/her_rewrite_rules.lua'}
    files['lua/her_rewrite_rules.lua'] = compile_project(project).encode('utf-8')
    files['default.custom.yaml'] = default_custom.encode('utf-8')
    if theme or not (target / 'squirrel.custom.yaml').exists():
        files['squirrel.custom.yaml'] = (ROOT / 'rime/squirrel.custom.yaml').read_bytes()
    # Recheck after reading/compiling so the plan never knowingly targets a
    # symlink introduced while preflight work was running.
    check_target(target)
    return InstallPlan(target, files, schema_patch)


def backup_target(target, backup):
    check_target(target)
    check_destination(backup, directory=True)
    backup.mkdir(parents=True, exist_ok=False)
    existed = []
    for name in TOUCHED_FILES:
        current = target / name
        check_destination(current)
        if current.is_file():
            destination = backup / name
            check_destination(destination)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(current, destination)
            existed.append(name)
    (backup / 'backup.json').write_text(json.dumps({
        'target': str(target), 'files_preexisting': existed,
        'files_touched': TOUCHED_FILES
    }, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def write_plan(plan):
    check_target(plan.target)
    plan.target.mkdir(parents=True, exist_ok=True)
    for name, data in plan.files.items():
        destination = plan.target / name
        check_destination(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        check_destination(destination)
        destination.write_bytes(data)


def run(arguments, **kwargs):
    subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def find_app(explicit):
    candidates = [Path(explicit).expanduser()] if explicit else [
        Path.home() / 'Library/Input Methods/Squirrel.app',
        Path('/Library/Input Methods/Squirrel.app')]
    for app in candidates:
        if (app / 'Contents/MacOS/rime_deployer').is_file():
            return app.resolve()
    raise RuntimeError('请先安装官方鼠须管，或使用 --app 指定其 Squirrel.app。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', help='官方 Squirrel.app 路径')
    parser.add_argument('--target', type=Path, default=Path.home() / 'Library/Rime')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'language-packs.json')
    parser.add_argument('--dry-run', action='store_true', help='仅检查并显示安装计划')
    parser.add_argument('--theme', action='store_true', help='使用本项目主题（原主题会备份）')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('此安装脚本只支持 macOS；语言包校验和编译不受此限制。')
    app = find_app(args.app)
    plan = prepare_plan(args.target, args.manifest, theme=args.theme)
    target = plan.target
    print('输入法：', app)
    print('配置目录：', target)
    print('安装她说方案；保留其他方案。默认中性表达，社群写法需手动切换。')
    print('输入来源补丁：patch/' + plan.schema_patch)
    print('计划写入：' + '、'.join(plan.files))
    if args.dry_run:
        print('检查完成，未写入配置或备份，也未调用部署器。')
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = Path.home() / 'Library/Application Support/HerWordsIME/backups' / stamp
    backup_target(target, backup)
    print('备份：', backup)
    write_plan(plan)
    deployer = app / 'Contents/MacOS/rime_deployer'
    check_target(target)
    run([deployer, '--build', target, app / 'Contents/SharedSupport', target / 'build'])
    run([deployer, '--set-active-schema', 'her_words'], cwd=target)
    run([app / 'Contents/MacOS/Squirrel', '--reload'])
    print('配置已部署。请从系统输入菜单选择鼠须管，按 Control + 反引号查看措辞开关。')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValidationError, subprocess.CalledProcessError) as error:
        print('安装未完成：' + str(error), file=sys.stderr)
        sys.exit(1)
