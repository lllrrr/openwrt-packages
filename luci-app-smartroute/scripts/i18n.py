#!/usr/bin/env python3
"""界面翻译：从 JS、菜单、rpcd 插件与 Go 后台的提示里抽取英文原文（msgid）。
  i18n.py pot     生成 luci/po/templates/smartroute.pot
  i18n.py check   检查 luci/po/*/smartroute.po 是否覆盖全部 msgid（CI 使用）
  i18n.py lmo <po> <lmo>   把 po 转成 LuCI 的 lmo（与 LuCI 的 po2lmo 相同格式，不需要编译它）
"""
import glob, json, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

def msgids():
    ids = []
    def add(s):
        if s not in ids:
            ids.append(s)
    for f in sorted(glob.glob(f'{ROOT}/luci/htdocs/**/*.js', recursive=True)):
        for m in re.finditer(r"_\('((?:[^'\\]|\\.)*)'\)", open(f).read()):
            add(m.group(1).replace("\\'", "'"))
    for v in json.load(open(f'{ROOT}/luci/root/usr/share/luci/menu.d/luci-app-smartroute.json')).values():
        add(v['title'])
    for m in re.finditer(r"error: '((?:[^'\\]|\\.)*)'", open(f'{ROOT}/luci/root/usr/share/rpcd/ucode/smartroute.uc').read()):
        add(m.group(1))
    for f in sorted(glob.glob(f'{ROOT}/internal/engine/*.go')):
        if not f.endswith('_test.go'):
            for m in re.finditer(r'(?:p\.warn|e\.event)\((?:\w+(?:\.\w+)?, )?"((?:[^"\\]|\\.)*)"', open(f).read()):
                add(json.loads('"' + m.group(1) + '"'))
    return ids

def po_quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'

def po_pairs(path):
    """po 里的 (msgid, msgstr)，跳过文件头"""
    txt, out = open(path).read(), []
    unq = lambda block: ''.join(json.loads(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"', block))
    for m in re.finditer(r'^msgid ((?:"(?:[^"\\]|\\.)*"\n?)+)msgstr ((?:"(?:[^"\\]|\\.)*"\n?)+)', txt, re.M):
        k, v = unq(m.group(1)), unq(m.group(2))
        if k and v:
            out.append((k, v))
    return out

def sfh(data):
    """LuCI lmo.c 的 sfh_hash（Paul Hsieh SuperFastHash，初值为长度）"""
    M, n = 0xffffffff, len(data)
    if n == 0:
        return 0
    h, i = n, 0
    sc = lambda b: b - 256 if b > 127 else b   # C 里的 signed char
    for _ in range(n >> 2):
        h = (h + (data[i] | data[i + 1] << 8)) & M
        tmp = (((data[i + 2] | data[i + 3] << 8) << 11) ^ h) & M
        h = ((h << 16) & M) ^ tmp
        i += 4
        h = (h + (h >> 11)) & M
    rem = n & 3
    if rem == 3:
        h = (h + (data[i] | data[i + 1] << 8)) & M
        h ^= (h << 16) & M
        h ^= (sc(data[i + 2]) << 18) & M
        h = (h + (h >> 11)) & M
    elif rem == 2:
        h = (h + (data[i] | data[i + 1] << 8)) & M
        h ^= (h << 11) & M
        h = (h + (h >> 17)) & M
    elif rem == 1:
        h = (h + sc(data[i])) & M
        h ^= (h << 10) & M
        h = (h + (h >> 1)) & M
    for sh, op in ((3, 'x'), (5, 'a'), (4, 'x'), (17, 'a'), (25, 'x'), (6, 'a')):
        h = (h ^ ((h << sh) & M)) if op == 'x' else ((h + (h >> sh)) & M)
    return h

def lmo(po, out):
    """译文依次写出（补齐到 4 字节），然后是按 msgid 哈希排序的索引（哈希、1、偏移、长度，大端），最后是索引的起始偏移"""
    import struct
    body, index = b'', []
    for k, v in po_pairs(po):
        kb, vb = k.encode(), v.encode()
        kid, vid = sfh(kb), sfh(vb)
        if kid == vid:
            continue
        index.append((kid, 1, len(body), len(vb)))
        body += vb + b'\0' * ((4 - len(vb) % 4) % 4)
    index.sort()
    with open(out, 'wb') as f:
        f.write(body + b''.join(struct.pack('>IIII', *e) for e in index) + struct.pack('>I', len(body)))
    return len(index)

def po_ids(path):
    ids, txt = set(), open(path).read()
    for m in re.finditer(r'^msgid ((?:"(?:[^"\\]|\\.)*"\n?)+)', txt, re.M):
        ids.add(''.join(json.loads(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"', m.group(1))))
    return ids

if __name__ == '__main__':
    ids = msgids()
    if sys.argv[1:] == ['pot']:
        with open(f'{ROOT}/luci/po/templates/smartroute.pot', 'w') as f:
            f.write('msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8"\n')
            for i in ids:
                f.write(f'\nmsgid {po_quote(i)}\nmsgstr ""\n')
        print(f'{len(ids)} msgids')
    elif sys.argv[1:] == ['check']:
        bad = 0
        for po in sorted(glob.glob(f'{ROOT}/luci/po/*/smartroute.po')):
            missing = [i for i in ids if i not in po_ids(po)]
            for i in missing:
                print(f'{po}: missing {i!r}')
            bad += len(missing)
        sys.exit(1 if bad else 0)
    elif sys.argv[1:2] == ['lmo'] and len(sys.argv) == 4:
        print(f'{lmo(sys.argv[2], sys.argv[3])} translations')
    else:
        sys.exit(__doc__)
