import ast
from collections import Counter
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
STRING = r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\""
TOKENS = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|' + STRING)
MESSAGE = re.compile(r'(?<![\w$])_\(\s*(' + STRING + r')\s*,\s*([\'\"])pulse\2\s*\)')
PLACEHOLDER = re.compile(r'%(?:%|(?:\d+\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?[sdifuxXoc])')


def read_po(path):
    entries = {}
    for block in path.read_text().split('\n\n'):
        fields, key = {}, None
        for line in block.splitlines():
            if not line or line.startswith('#'):
                continue
            match = re.fullmatch(r'(msgctxt|msgid|msgstr) (".*")', line)
            if match:
                key = match[1]
                fields[key] = ast.literal_eval(match[2])
            elif line.startswith('"') and key:
                fields[key] += ast.literal_eval(line)
            else:
                raise AssertionError(f'{path}: 不支持的 PO 条目: {line}')
        if not fields.get('msgid'):
            continue
        identity = (fields.get('msgctxt'), fields['msgid'])
        if identity in entries:
            raise AssertionError(f'{path}: 重复文案: {identity}')
        if re.search(r'^#,.*\bfuzzy\b', block, re.M):
            raise AssertionError(f'{path}: 尚未确认的模糊翻译: {identity}')
        entries[identity] = fields.get('msgstr', '')
    return entries


def messages_from_js(source):
    # 保留字符串内的 URL, 仅忽略注释, 允许中文注释而不将其视为界面文案.
    source = TOKENS.sub(lambda match: ' ' if match[0].startswith(('//', '/*')) else match[0], source)
    return {('pulse', ast.literal_eval(match[1])) for match in MESSAGE.finditer(source)}


class TranslationTests(unittest.TestCase):
    def test_source_messages_match_template(self):
        """界面文案与翻译模板一致."""
        messages = set()
        for path in (ROOT / 'htdocs').rglob('*.js'):
            messages.update(messages_from_js(path.read_text()))
        for path in (ROOT / 'root/usr/share/luci/menu.d').glob('*.json'):
            for entry in json.loads(path.read_text()).values():
                if 'title' in entry:
                    messages.add((None, entry['title']))
        self.assertEqual(messages, set(read_po(ROOT / 'po/templates/pulse.pot')))

    def test_all_languages_have_complete_messages_and_placeholders(self):
        """所有语言的文案完整且占位符一致."""
        template = read_po(ROOT / 'po/templates/pulse.pot')
        catalogs = sorted(path for path in (ROOT / 'po').glob('*/pulse.po') if path.parent.name != 'templates')
        self.assertTrue(catalogs, '没有找到翻译目录')
        for catalog in catalogs:
            with self.subTest(language=catalog.parent.name):
                messages = read_po(catalog)
                self.assertEqual(set(messages), set(template))
                for (_, original), translated in messages.items():
                    with self.subTest(message=original):
                        self.assertTrue(translated.strip(), '翻译为空')
                        self.assertEqual(Counter(PLACEHOLDER.findall(original)),
                                         Counter(PLACEHOLDER.findall(translated)))
                        self.assertEqual(original, original.strip())

    def test_chinese_comments_do_not_create_translation_entries(self):
        """中文代码注释不会被误识别为待翻译文案."""
        source = '''// 中文注释, _('Ignored', 'pulse').
        /* 中文注释, _('Also ignored', 'pulse'). */
        const url = 'https://example.invalid/';
        _('Up', 'pulse'); _("Down", "pulse");
        '''
        self.assertEqual(messages_from_js(source), {('pulse', 'Up'), ('pulse', 'Down')})
