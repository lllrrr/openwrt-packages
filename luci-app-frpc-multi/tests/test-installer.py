#!/usr/bin/env python3
"""Isolated installer tests: fake feeds/downloads; never change system /etc or binaries."""
import hashlib,io,os,pathlib,subprocess,tarfile,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
source=(repo/'install.sh').read_text()
cases=[('apk','aarch64','aarch64_generic',False),('apk','aarch64','aarch64_cortex-a53',True),('apk','aarch64','aarch64',False),('apk','x86_64','x86_64',False),('opkg','aarch64','aarch64_generic',True),('opkg','aarch64','aarch64_cortex-a53',True),('opkg','x86_64','x86_64',True)]
for mode,arch,pkgarch,old in cases:
 with tempfile.TemporaryDirectory() as d:
  t=pathlib.Path(d);bin=t/'bin';bin.mkdir();fake=t/'fs';fake.mkdir()
  frparch='arm64' if arch=='aarch64' else 'amd64'
  payload=b'fixture-package';digest=hashlib.sha256(payload).hexdigest()
  core=b'#!/bin/sh\n[ "$1" = verify ] && exit 0\necho 0.66.0\n'
  archive=t/'core.tar.gz'
  with tarfile.open(archive,'w:gz') as f:
   m=tarfile.TarInfo('frp_0.66.0_linux_'+frparch+'/frpc');m.size=len(core);m.mode=0o755;f.addfile(m,io.BytesIO(core))
  sha=hashlib.sha256(archive.read_bytes()).hexdigest()
  filename='luci-app-frpc-multi-1.0.0-r11-noarch.apk' if mode=='apk' else 'luci-app-frpc-multi_1.0.0-r11_all.ipk'
  (t/'sums').write_text(digest+'  '+filename+'\n');(t/'package').write_bytes(payload)
  def executable(path,content):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(content);path.chmod(0o755)
  executable(bin/'id','#!/bin/sh\necho 0\n')
  executable(bin/'uname','#!/bin/sh\necho '+arch+'\n')
  for cmd in ['apk','opkg']:
   executable(bin/cmd,'#!/bin/sh\nif [ "$1" = --print-arch ]; then echo '+pkgarch+'; exit 0; fi\nif [ "$1" = print-architecture ]; then printf "arch all 1\\narch '+pkgarch+' 10\\n"; exit 0; fi\necho "'+cmd+' $*" >> "$TEST_LOG"\n')
  executable(bin/'wget','#!/bin/sh\ncase "$3" in */SHA256SUMS) cp "$TEST_FIX/sums" "$2";; *.apk|*.ipk) cp "$TEST_FIX/package" "$2";; *.tar.gz) cp "$TEST_FIX/core.tar.gz" "$2";; *) exit 1;; esac\n')
  executable(fake/'usr/bin/frpc','#!/bin/sh\n[ "$1" = verify ] && exit '+('1' if old else '0')+'\necho '+('0.51.3' if old else '0.66.0')+'\n')
  executable(fake/'etc/init.d/frpc-multi','#!/bin/sh\necho "reload $*" >> "$TEST_LOG"\n')
  s=source.replace('/usr/bin/frpc',str(fake/'usr/bin/frpc')).replace('/usr/lib/frpc-multi',str(fake/'usr/lib/frpc-multi')).replace('/lib/upgrade/keep.d',str(fake/'lib/upgrade/keep.d')).replace('/etc/init.d/frpc-multi',str(fake/'etc/init.d/frpc-multi'))
  s=s.replace('196ddaa51b716c2e99aeb2916b0a2bf55bb317494c4acdcefab36c383de950ba',sha).replace('317a17a7adac2e6bed2d7a83dc077da91ced0d110e1636373ece8ae5ac8b578b',sha)
  script=t/'install.sh';script.write_text(s)
  env=dict(os.environ,PATH=str(bin)+':'+os.environ['PATH'],FRPC_MULTI_PKG_MODE=mode,TEST_LOG=str(t/'log'),TEST_FIX=str(t))
  r=subprocess.run(['sh',str(script)],env=env,capture_output=True,text=True)
  assert r.returncode==0,(mode,arch,r.stdout,r.stderr)
  log=(t/'log').read_text();assert mode+' update' in log and filename in log and 'reload' in log
  assert (fake/'usr/lib/frpc-multi/frpc').exists()==old
  assert ('echo 0.51.3' in (fake/'usr/bin/frpc').read_text())==old
  print('PASS',mode,arch,pkgarch,'universal asset + SHA256 + dependencies + reload;', 'old core upgraded privately' if old else 'compatible system core retained')
print('All installer tests use mocked package managers; real feed downloads / service startup not covered')
