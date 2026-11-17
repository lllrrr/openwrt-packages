#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import shutil
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps([command, *args]) + '\n')

if command == 'id':
    print(os.environ.get('MOCK_UID', '0'))
elif command == 'uclient-fetch':
    url = args[-1]
    name = 'release.json' if url.endswith('/releases/latest') else url.rsplit('/', 1)[-1]
    if name == os.environ.get('FAIL_DOWNLOAD'):
        sys.exit(1)
    shutil.copyfile(Path(os.environ['FIXTURES']) / name, args[args.index('-O') + 1])
elif command == 'jsonfilter':
    assets = json.loads(Path(args[args.index('-i') + 1]).read_text())['assets']
    expression = args[args.index('-e') + 1]
    if expression == '@.assets[*].browser_download_url':
        for asset in assets:
            print(asset['browser_download_url'])
    else:
        match = re.fullmatch(r'@\.assets\[@\.name="([^"]+)"\]\.digest', expression)
        if not match:
            raise SystemExit(f'非预期的 jsonfilter 表达式: {expression}')
        for asset in assets:
            if asset['name'] == match[1] and asset.get('digest') is not None:
                print(asset['digest'])
elif command == 'apk':
    if args[:2] != ['add', '--allow-untrusted']:
        raise SystemExit(f'非预期的 apk 操作: {args}')
    if not args[2:] or not all(Path(name).is_file() for name in args[2:]):
        raise SystemExit('缺少软件包文件')
    sys.exit(int(os.environ.get('APK_FAIL', '0')))
elif command == 'mock-service':
    if args not in [['pulse-traffic', 'enable'], ['pulse-traffic', 'restart'], ['rpcd', 'reload']]:
        raise SystemExit(f'非预期的服务操作: {args}')
else:
    raise SystemExit(f'非预期的命令: {command}')
