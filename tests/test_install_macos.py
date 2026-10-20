"""Installer planning and path regressions; never calls a live Rime deployer."""

import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import install_macos as installer  # noqa: E402


def patched(text):
    result, selected = installer.plan_default_custom(text)
    return yaml.safe_load(result), selected


class CustomYamlTests(unittest.TestCase):
    def test_existing_explicit_list_preserves_other_settings(self):
        original = '''config_version: "1"
other:
  preserve: [alpha, beta]
patch:
  schema_list:
    - schema: luna_pinyin
    - schema: bopomofo
      custom_flag: true
  menu/page_size: 9
'''
        result, key = patched(original)
        expected = yaml.safe_load(original)
        expected['patch']['schema_list'].append({'schema': 'her_words'})
        self.assertEqual(key, 'schema_list')
        self.assertEqual(result, expected)
        self.assertNotIn('schema_list/+', result['patch'])

    def test_existing_append_list_keeps_inherited_schemas(self):
        result, key = patched('patch:\n  schema_list/+:\n    - schema: existing_extra\n  menu/page_size: 8\n')
        self.assertEqual(key, 'schema_list/+')
        self.assertEqual(result['patch']['schema_list/+'],
                         [{'schema': 'existing_extra'}, {'schema': 'her_words'}])
        self.assertNotIn('schema_list', result['patch'])
        self.assertEqual(result['patch']['menu/page_size'], 8)

    def test_no_configuration_uses_append_patch(self):
        for text in ('', '# Empty custom configuration\n', 'other: keep\n', 'patch: {}\n'):
            with self.subTest(text=text):
                result, key = patched(text)
                self.assertEqual(key, 'schema_list/+')
                self.assertEqual(result['patch']['schema_list/+'], [{'schema': 'her_words'}])
                self.assertNotIn('schema_list', result['patch'])

    def test_both_keys_use_explicit_list_and_preserve_append(self):
        result, key = patched('patch:\n  schema_list: [{schema: base}]\n  schema_list/+: [{schema: extra}]\n')
        self.assertEqual(key, 'schema_list')
        self.assertEqual(result['patch']['schema_list'], [{'schema': 'base'}, {'schema': 'her_words'}])
        self.assertEqual(result['patch']['schema_list/+'], [{'schema': 'extra'}])

    def test_existing_her_words_remains_idempotent_in_either_list(self):
        for text in (
            'patch:\n  schema_list: [{schema: base}, {schema: her_words}]\n',
            'patch:\n  schema_list/+: [{schema: her_words}]\n',
            'patch:\n  schema_list: [{schema: base}]\n  schema_list/+: [{schema: her_words}]\n',
        ):
            with self.subTest(text=text):
                first, _ = installer.plan_default_custom(text)
                second, _ = installer.plan_default_custom(first)
                self.assertEqual(yaml.safe_load(first), yaml.safe_load(text))
                self.assertEqual(first, second)

    def test_bad_root_patch_and_list_types_are_rejected(self):
        invalid = [
            '[]', 'null', 'text', 'patch: null', 'patch: []',
            'patch: {schema_list: null}', 'patch: {schema_list: single}',
            'patch: {schema_list/+: {schema: foo}}',
            'patch: {schema_list: [plain_name]}',
            'patch: {schema_list: [{}]}',
            'patch: {schema_list: [{schema: 3}]}',
            'patch: {schema_list: [{schema: ""}]}',
            # Validate both keys even when the first one would be selected.
            'patch: {schema_list: [], schema_list/+: wrong}',
        ]
        for text in invalid:
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                installer.plan_default_custom(text)

    def test_duplicate_yaml_keys_rejected_at_every_depth(self):
        for text in (
            'patch: {}\npatch: {}',
            'patch:\n  schema_list: []\n  schema_list: []',
            'patch:\n  menu: {page_size: 7, page_size: 8}',
            'base: &base {schema_list: []}\npatch:\n  <<: *base\n  <<: *base',
        ):
            with self.subTest(text=text), self.assertRaisesRegex(RuntimeError, 'duplicate YAML key'):
                installer.plan_default_custom(text)

    def test_unsafe_yaml_tags_and_multiple_documents_rejected(self):
        for text in (
            'patch: !!python/object/apply:os.system ["never execute"]',
            'patch: !UnknownCustomTag {}',
            'patch: {}\n---\npatch: {}',
        ):
            with self.subTest(text=text), mock.patch('os.system') as execute:
                with self.assertRaises(RuntimeError):
                    installer.plan_default_custom(text)
                execute.assert_not_called()

    def test_yaml_merges_preserve_effective_values_without_changing_anchors(self):
        text = '''base: &base
  schema_list: [{schema: luna_pinyin}]
  menu/page_size: 7
profile: &profile
  <<: *base
  menu/page_size: 9
patch:
  <<: *profile
  menu/page_size: 11
'''
        result, _ = patched(text)
        original = yaml.safe_load(text)
        self.assertEqual(result['base'], original['base'])
        self.assertEqual(result['profile'], original['profile'])
        self.assertEqual(result['patch']['menu/page_size'], 11)
        self.assertEqual(result['patch']['schema_list'],
                         [{'schema': 'luna_pinyin'}, {'schema': 'her_words'}])

    def test_aliased_patch_mapping_is_not_edited_elsewhere(self):
        text = 'profile: &profile {schema_list: [{schema: base}]}\npatch: *profile\n'
        result, _ = patched(text)
        self.assertEqual(result['profile'], {'schema_list': [{'schema': 'base'}]})
        self.assertEqual(len(result['patch']['schema_list']), 2)


class InstallerPlanTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        # macOS /var and /tmp are OS aliases. Tests use their resolved temporary
        # directory so path tests deliberately introduce each symlink themselves.
        self.root = Path(temporary.name).resolve()
        self.target = self.root / 'Rime'
        self.outside = self.root / 'outside'
        self.outside.mkdir()

    def plan(self):
        return installer.prepare_plan(self.target, ROOT / 'language-packs.json')

    def test_preflight_compiles_every_file_without_creating_target(self):
        plan = self.plan()
        self.assertFalse(self.target.exists())
        self.assertEqual(plan.schema_patch, 'schema_list/+')
        self.assertEqual(set(plan.files), set(installer.OWN_FILES) |
                         {'default.custom.yaml', 'squirrel.custom.yaml'})
        config = yaml.safe_load(plan.files['default.custom.yaml'])
        self.assertEqual(config, {'patch': {'schema_list/+': [{'schema': 'her_words'}]}})
        self.assertIn(b'return {', plan.files['lua/her_rewrite_rules.lua'])

    def test_existing_theme_is_preserved_unless_requested(self):
        self.target.mkdir()
        theme = self.target / 'squirrel.custom.yaml'
        theme.write_text('patch: {style/color_scheme: my_theme}\n', encoding='utf-8')
        self.assertNotIn('squirrel.custom.yaml', self.plan().files)
        with_theme = installer.prepare_plan(self.target, ROOT / 'language-packs.json', theme=True)
        self.assertIn('squirrel.custom.yaml', with_theme.files)
        self.assertIn('my_theme', theme.read_text(encoding='utf-8'))

    def test_bad_yaml_stops_before_compile_or_backup_or_writes(self):
        self.target.mkdir()
        config = self.target / 'default.custom.yaml'
        config.write_text('patch: {schema_list: wrong}\n', encoding='utf-8')
        original = config.read_bytes()
        with mock.patch.object(installer, 'load_project') as compile_packs:
            with self.assertRaises(RuntimeError):
                self.plan()
            compile_packs.assert_not_called()
        self.assertEqual(config.read_bytes(), original)
        self.assertEqual([path.name for path in self.target.iterdir()], ['default.custom.yaml'])

    def test_every_known_destination_rejects_symlinks_including_broken_links(self):
        for index, name in enumerate(installer.TOUCHED_FILES):
            with self.subTest(name=name):
                target = self.root / ('target-' + str(index))
                destination = target / name
                destination.parent.mkdir(parents=True)
                destination.symlink_to(self.outside / 'missing-file')
                with self.assertRaisesRegex(RuntimeError, '符号链接'):
                    installer.check_target(target)

    def test_lua_parent_symlink_is_rejected_before_compile(self):
        self.target.mkdir()
        (self.target / 'lua').symlink_to(self.outside, target_is_directory=True)
        with mock.patch.object(installer, 'load_project') as compile_packs:
            with self.assertRaisesRegex(RuntimeError, '符号链接'):
                self.plan()
            compile_packs.assert_not_called()
        self.assertEqual(list(self.outside.iterdir()), [])

    def test_target_and_ancestor_symlinks_are_not_hidden_by_resolve(self):
        self.target.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, '符号链接'):
            self.plan()
        parent_link = self.root / 'linked-parent'
        parent_link.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, '符号链接'):
            installer.check_target(parent_link / 'Rime')

    def test_build_symlink_and_nested_build_symlink_rejected(self):
        self.target.mkdir()
        build = self.target / 'build'
        build.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, '符号链接'):
            self.plan()
        build.unlink()
        (build / 'nested').mkdir(parents=True)
        (build / 'nested/cache.bin').symlink_to(self.outside / 'missing')
        with self.assertRaisesRegex(RuntimeError, '符号链接'):
            self.plan()

    def test_wrong_file_or_parent_type_rejected(self):
        self.target.mkdir()
        (self.target / 'lua').write_text('not a directory', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, '类型异常'):
            self.plan()
        (self.target / 'lua').unlink()
        (self.target / 'her_words.schema.yaml').mkdir()
        with self.assertRaisesRegex(RuntimeError, '类型异常'):
            self.plan()

    def test_path_recheck_detects_symlink_added_after_planning(self):
        plan = self.plan()
        self.target.mkdir()
        (self.target / 'lua').symlink_to(self.outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, '符号链接'):
            installer.write_plan(plan)
        self.assertFalse((self.target / 'her_words.schema.yaml').exists())
        self.assertEqual(list(self.outside.iterdir()), [])

    def test_dry_run_performs_full_plan_without_mutations_or_deployment(self):
        arguments = ['install_macos.py', '--dry-run', '--target', str(self.target)]
        with mock.patch.object(sys, 'argv', arguments), \
                mock.patch.object(installer.platform, 'system', return_value='Darwin'), \
                mock.patch.object(installer, 'find_app', return_value=self.root / 'Squirrel.app'), \
                mock.patch.object(installer, 'run') as deploy, \
                mock.patch.object(installer, 'backup_target') as backup, \
                mock.patch.object(installer, 'write_plan') as write, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            installer.main()
        deploy.assert_not_called()
        backup.assert_not_called()
        write.assert_not_called()
        self.assertFalse(self.target.exists())
        self.assertIn('schema_list/+', output.getvalue())

    def test_main_rejects_bad_yaml_before_any_mutation_without_dry_run(self):
        self.target.mkdir()
        (self.target / 'default.custom.yaml').write_text('patch: null', encoding='utf-8')
        arguments = ['install_macos.py', '--target', str(self.target)]
        with mock.patch.object(sys, 'argv', arguments), \
                mock.patch.object(installer.platform, 'system', return_value='Darwin'), \
                mock.patch.object(installer, 'find_app', return_value=self.root / 'Squirrel.app'), \
                mock.patch.object(installer, 'run') as deploy, \
                mock.patch.object(installer, 'backup_target') as backup, \
                mock.patch.object(installer, 'write_plan') as write:
            with self.assertRaises(RuntimeError):
                installer.main()
        deploy.assert_not_called()
        backup.assert_not_called()
        write.assert_not_called()


if __name__ == '__main__':
    unittest.main()
