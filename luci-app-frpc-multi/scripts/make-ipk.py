#!/usr/bin/env python3
"""Build an OpenWrt opkg IPK: gzip/tar outer archive, not Debian ar."""
import argparse, io, os, pathlib, stat, tarfile
p=argparse.ArgumentParser()
p.add_argument('--root',required=True);p.add_argument('--out',required=True)
p.add_argument('--scripts',required=True);p.add_argument('--name',default='luci-app-frpc-multi')
p.add_argument('--version',required=True);p.add_argument('--arch',required=True)
p.add_argument('--license',default='Apache-2.0 AND GPL-2.0-only')
p.add_argument('--url',default='https://github.com/myc2002/luci-app-frpc-multi')
a=p.parse_args();root=pathlib.Path(a.root);out=pathlib.Path(a.out);scripts=pathlib.Path(a.scripts)

os.chmod(root/'etc/init.d/frpc-multi',0o755)
os.chmod(root/'usr/sbin/frpc-multi-watchdog',0o755)
os.chmod(root/'etc/config/frpc_multi',0o600)
for rel in ('usr/share/rpcd/ucode/luci.frpc-multi','usr/share/luci/menu.d/luci-app-frpc-multi.json','usr/share/rpcd/acl.d/luci-app-frpc-multi.json','www/luci-static/resources/view/frpc-multi.js'):
    os.chmod(root/rel,0o644)
pkglist=root/'usr/lib/opkg/info'/f'{a.name}.list';pkglist.parent.mkdir(parents=True,exist_ok=True)
files=sorted('/'+str(x.relative_to(root)) for x in root.rglob('*') if x.is_file() and 'usr/lib/opkg/info' not in str(x.relative_to(root)))
pkglist.write_text('\n'.join(files)+'\n')
control='\n'.join([f'Package: {a.name}',f'Version: {a.version}',f'Architecture: {a.arch}','Priority: optional','Section: net','Maintainer: luci-app-frpc-multi contributors',f'License: {a.license}',f'URL: {a.url}','Depends: frpc, luci-base, rpcd-mod-ucode, ucode-mod-uci, ucode-mod-ubus, ucode-mod-fs, ucode-mod-socket','Description: LuCI app for independent multi-server frpc connections, live status and watchdog.',''])
def tar_bytes(entries):
    f=io.BytesIO()
    with tarfile.open(fileobj=f,mode='w:gz',format=tarfile.USTAR_FORMAT) as t:
        dirs=set()
        for arc,src,mode in entries:
            parent=pathlib.PurePosixPath(arc).parent
            parents=[]
            while str(parent) not in ('.','/'):
                parents.append(str(parent));parent=parent.parent
            for directory in reversed(parents):
                if directory in dirs:continue
                dirs.add(directory)
                ti=tarfile.TarInfo('./'+directory+'/');ti.type=tarfile.DIRTYPE;ti.mode=0o755;ti.uid=ti.gid=0;ti.mtime=0;t.addfile(ti)
            data=src if isinstance(src,bytes) else pathlib.Path(src).read_bytes()
            ti=tarfile.TarInfo(arc if arc.startswith('./') else './'+arc);ti.size=len(data);ti.mode=mode;ti.uid=ti.gid=0;ti.uname='root';ti.gname='root';ti.mtime=0;t.addfile(ti,io.BytesIO(data))
    return f.getvalue()
control_tar=tar_bytes([('control',control.encode(),0o644),('conffiles',b'/etc/config/frpc_multi\n',0o644),('postinst',scripts/'post-install',0o755),('prerm',scripts/'pre-deinstall',0o755)])
def file_mode(f):
    rel=str(f.relative_to(root))
    return 0o755 if rel in ('etc/init.d/frpc-multi','usr/sbin/frpc-multi-watchdog') else (0o600 if rel=='etc/config/frpc_multi' else 0o644)
data_tar=tar_bytes([(str(f.relative_to(root)),f,file_mode(f)) for f in sorted(root.rglob('*')) if f.is_file() and 'usr/lib/opkg/info' not in str(f.relative_to(root))])
blob=tar_bytes([('./debian-binary',b'2.0\n',0o644),('./control.tar.gz',control_tar,0o644),('./data.tar.gz',data_tar,0o644)])
out.mkdir(parents=True,exist_ok=True);target=out/f'{a.name}_{a.version}_{a.arch}.ipk';target.write_bytes(blob);os.chmod(target,0o644);print(target,len(blob))
