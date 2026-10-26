import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile


PACKAGE = 'luci-app-webrtc-guard'
LEGACY_PACKAGE = 'luci-app-webrtc-control'
VERSION = '1.2.3'
RELEASE = '1'
DEPENDENCIES = ['libc', 'luci-base', 'firewall4', 'kmod-nft-core', 'nftables-json', 'jsonfilter', 'flock']
APK_DEPENDENCIES = [dependency for dependency in DEPENDENCIES if dependency != 'flock'] + ['busybox', '!' + LEGACY_PACKAGE]
SOURCE = Path(__file__).resolve().parent
EXECUTABLES = {
    'etc/init.d/webrtc-control',
    'etc/uci-defaults/40_luci-webrtc-control',
    'usr/libexec/rpcd/webrtc-control',
    'usr/share/webrtc-control/apply.sh',
    'usr/share/webrtc-control/common.sh',
}
POST_INSTALL = '''#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
command -v flock >/dev/null 2>&1 || { echo '缺少 flock 命令，请先补齐运行环境' >&2; exit 1; }
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload || exit 1
/etc/init.d/webrtc-control enable || exit 1
/etc/init.d/webrtc-control start || exit 1
rm -f /etc/uci-defaults/40_luci-webrtc-control
exit 0
'''
PRE_REMOVE = '''#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
[ "${1:-}" != upgrade ] || exit 0
/etc/init.d/webrtc-control stop || exit 1
/etc/init.d/webrtc-control disable || exit 1
exit 0
'''
POST_REMOVE = '''#!/bin/sh
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload || exit 1
exit 0
'''


def normalized_content(path):
    return path.read_bytes().replace(b'\r\n', b'\n')


def write_payload(stage):
    for source_root, prefix in [(SOURCE / 'root', ''), (SOURCE / 'htdocs', 'www')]:
        for source_path in sorted(source_root.rglob('*')):
            if not source_path.is_file():
                continue
            relative = Path(prefix) / source_path.relative_to(source_root)
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(normalized_content(source_path))
            destination.chmod(0o755 if relative.as_posix() in EXECUTABLES else 0o644)


def tar_archive(entries):
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode='wb', filename='', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for name, content, mode in entries:
                metadata = tarfile.TarInfo('./' + name)
                metadata.size = len(content)
                metadata.mode = mode
                metadata.uid = metadata.gid = 0
                metadata.uname = metadata.gname = 'root'
                metadata.mtime = 0
                archive.addfile(metadata, io.BytesIO(content))
    return output.getvalue()


def build_ipk(stage, output):
    files = [(path.relative_to(stage).as_posix(), path.read_bytes(), 0o755 if path.relative_to(stage).as_posix() in EXECUTABLES else 0o644) for path in sorted(stage.rglob('*')) if path.is_file()]
    size = sum(len(content) for _, content, _ in files)
    control = f'''Package: {PACKAGE}
Version: {VERSION}-{RELEASE}
Architecture: all
Maintainer: meesii
Depends: {', '.join(DEPENDENCIES)}
Conflicts: {LEGACY_PACKAGE}
Section: luci
Priority: optional
License: GPL-3.0-or-later
Installed-Size: {size}
Description: STUN egress leak guard for OpenClash and fw4
 Checks forwarded and local DIRECT output without whole-IP blocking.
'''
    controls = [
        ('control', control.encode(), 0o644),
        ('conffiles', b'/etc/config/webrtc-control\n', 0o644),
        ('postinst', POST_INSTALL.encode(), 0o755),
        ('prerm', PRE_REMOVE.encode(), 0o755),
        ('postrm', POST_REMOVE.encode(), 0o755),
    ]
    package = tar_archive([
        ('debian-binary', b'2.0\n', 0o644),
        ('control.tar.gz', tar_archive(controls), 0o644),
        ('data.tar.gz', tar_archive(files), 0o644),
    ])
    destination = output / f'{PACKAGE}_{VERSION}-{RELEASE}_all.ipk'
    destination.write_bytes(package)
    return destination


def build_apk(stage, scripts, output, apk):
    package_metadata = stage / 'lib/apk/packages'
    package_metadata.mkdir(parents=True)
    configuration = '/etc/config/webrtc-control'
    digest = hashlib.sha256((stage / configuration.lstrip('/')).read_bytes()).hexdigest()
    (package_metadata / f'{PACKAGE}.conffiles').write_text(configuration + '\n')
    (package_metadata / f'{PACKAGE}.conffiles_static').write_text(f'{configuration} {digest}\n')
    file_list = sorted('/' + path.relative_to(stage).as_posix() for path in stage.rglob('*') if path.is_file())
    (package_metadata / f'{PACKAGE}.list').write_text('\n'.join(file_list) + '\n')
    script_paths = {}
    for name, content in [('post-install', POST_INSTALL), ('post-upgrade', POST_INSTALL), ('pre-deinstall', PRE_REMOVE), ('post-deinstall', POST_REMOVE)]:
        path = scripts / name
        path.write_text(content, encoding='utf8', newline='\n')
        path.chmod(0o755)
        script_paths[name] = path
    destination = output / f'{PACKAGE}-{VERSION}-r{RELEASE}.apk'
    arguments = [apk, 'mkpkg']
    for field in [
        f'name:{PACKAGE}', f'version:{VERSION}-r{RELEASE}', 'arch:noarch',
        'license:GPL-3.0-or-later', f'origin:{PACKAGE}',
        'description:STUN egress leak guard for OpenClash and fw4',
        'url:https://github.com/meesii/luci-app-webrtc-guard',
        'depends:' + ' '.join(APK_DEPENDENCIES),
    ]:
        arguments.extend(['--info', field])
    for name, path in script_paths.items():
        arguments.extend(['--script', f'{name}:{path}'])
    arguments.extend(['--files', str(stage), '--output', str(destination)])
    environment = os.environ.copy()
    environment['SOURCE_DATE_EPOCH'] = '0'
    subprocess.run(arguments, check=True, env=environment)
    return destination


def offline_installer(apk, output):
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    destination = output / 'install-offline.sh'
    destination.write_text(f'''#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package="$directory/{apk.name}"
[ -f "$package" ] || {{ echo '请把安装脚本与 APK 放在同一个目录' >&2; exit 1; }}
printf '%s  %s\\n' '{digest}' "$package" | sha256sum -c -
command -v flock >/dev/null 2>&1 || {{ echo '系统缺少 flock，无法离线安装' >&2; exit 1; }}
apk --no-network --repositories-file /dev/null add --allow-untrusted "$package"
''', encoding='utf8', newline='\n')
    destination.chmod(0o755)
    return destination


def source_archive(output):
    destination = output / f'{PACKAGE}-{VERSION}-source.zip'
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(SOURCE.rglob('*')):
            relative = path.relative_to(SOURCE)
            if not path.is_file() or any(part in {'.git', 'dist', '__pycache__'} for part in relative.parts):
                continue
            metadata = zipfile.ZipInfo((Path(PACKAGE) / relative).as_posix())
            metadata.date_time = (2026, 1, 1, 0, 0, 0)
            metadata.external_attr = (0o755 if relative.as_posix().removeprefix('root/') in EXECUTABLES else 0o644) << 16
            metadata.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(metadata, normalized_content(path))
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=SOURCE / 'dist')
    parser.add_argument('--apk-tool', default=os.environ.get('APK_TOOL'))
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='webrtc-guard-build-') as temporary:
        stage = Path(temporary) / 'data'
        stage.mkdir()
        write_payload(stage)
        built = [build_ipk(stage, output)]
        if arguments.apk_tool:
            scripts = Path(temporary) / 'scripts'
            scripts.mkdir()
            apk = build_apk(stage, scripts, output, arguments.apk_tool)
            built.append(apk)
            built.append(offline_installer(apk, output))
        built.append(source_archive(output))
    shutil.copyfile(SOURCE / 'README.md', output / '安装说明.md')
    checksums = []
    for path in built:
        checksums.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}')
        print(path)
    (output / 'SHA256SUMS').write_text('\n'.join(checksums) + '\n')


if __name__ == '__main__':
    main()
