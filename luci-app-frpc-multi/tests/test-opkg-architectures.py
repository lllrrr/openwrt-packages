#!/usr/bin/env python3
"""Run with OPKG_BIN and (if needed) LD_LIBRARY_PATH. Offline dummy dependencies only."""
import io,os,pathlib,shutil,subprocess,tarfile,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
opkg=os.environ['OPKG_BIN']
deps=['frpc','luci-base','rpcd-mod-ucode','ucode-mod-uci','ucode-mod-ubus','ucode-mod-fs','ucode-mod-socket']
with tempfile.TemporaryDirectory() as d:
 t=pathlib.Path(d)
 stage=t/'stage';shutil.copytree(repo/'root',stage)
 subprocess.run(['python3',str(repo/'scripts/make-ipk.py'),'--root',str(stage),'--scripts',str(repo/'scripts'),'--out',str(t),'--version','1.0.0-r10','--arch','all'],check=True)
 package=t/'luci-app-frpc-multi_1.0.0-r10_all.ipk'
 with tarfile.open(package,'r:gz') as outer:
  with tarfile.open(fileobj=io.BytesIO(outer.extractfile('./control.tar.gz').read()),mode='r:gz') as control:
   assert 'Architecture: all\n' in control.extractfile('./control').read().decode()
 for arch in ['aarch64_generic','aarch64_cortex-a53','x86_64']:
  root=t/arch
  (root/'var/lock').mkdir(parents=True)
  status=root/'usr/lib/opkg/status';status.parent.mkdir(parents=True)
  status.write_text(''.join('Package: '+n+'\nVersion: 99\nArchitecture: '+arch+'\nStatus: install ok installed\n\n' for n in deps))
  config=t/(arch+'.conf');config.write_text('dest root /\narch all 1\narch '+arch+' 10\n')
  cmd=[opkg,'-f',str(config),'-o',str(root)]
  r=subprocess.run(cmd+['install',str(package)],text=True,capture_output=True)
  assert r.returncode==0,(arch,r.stdout,r.stderr)
  assert (root/'etc/config/frpc_multi').stat().st_mode&0o777==0o600
  assert (root/'etc/init.d/frpc-multi').stat().st_mode&0o777==0o755
  cfg=root/'etc/config/frpc_multi';cfg.write_text(cfg.read_text()+'\n# preserved test\n')
  subprocess.run(['python3',str(repo/'scripts/make-ipk.py'),'--root',str(stage),'--scripts',str(repo/'scripts'),'--out',str(t),'--version','1.0.0-r11','--arch','all'],check=True,capture_output=True)
  r=subprocess.run(cmd+['install',str(t/'luci-app-frpc-multi_1.0.0-r11_all.ipk')],text=True,capture_output=True)
  assert r.returncode==0 and '# preserved test' in cfg.read_text(),(arch,r.stdout,r.stderr)
  subprocess.run(['python3',str(repo/'scripts/make-ipk.py'),'--root',str(stage),'--scripts',str(repo/'scripts'),'--out',str(t),'--name','frpc-arch-negative-probe','--version','1.0.0-r12','--arch','aarch64'],check=True,capture_output=True)
  r=subprocess.run(cmd+['install',str(t/'frpc-arch-negative-probe_1.0.0-r12_aarch64.ipk')],text=True,capture_output=True)
  assert 'Version: 1.0.0-r12\n' not in status.read_text(),(arch,'incorrect architecture installed',r.stdout,r.stderr)
  assert 'incompatible' in (r.stdout+r.stderr).lower() or 'architecture' in (r.stdout+r.stderr).lower(),(arch,r.stdout,r.stderr)
  print('PASS real opkg',arch,'all installation + permissions + preserved upgrade; wrong CPU tag rejected')
print('Offline fixture dependencies: does not test live feeds, procd or router runtime.')
