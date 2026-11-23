#!/bin/sh
# smartroute PVE 测试环境：创建 / 启动 / 停止 / 销毁测试虚拟机（只用 lab@pve 的受限 token）
# 用法: TOKENFILE=~/.config/pve-lab-token ./vms.sh create|start|stop|destroy [vmid...]
#   TOKENFILE 内容:  PVE=https://<pve>:8006/api2/json  和  TOK=lab@pve!api=<secret>
# 前置（需 root 一次性完成）：SDN zone lab + vnet labwan/lablan、pool lab、lab@pve 账号与 ACL、
#   local:import/ 下的 lab-iwrt-24.10.raw / lab-iwrt-25.12.raw（已注入 99-smartroute-lab）与 Alpine cloud 镜像
. "${TOKENFILE:-$HOME/.config/pve-lab-token}"
api() { curl -sk -m 120 -H "Authorization: PVEAPIToken=$TOK" "$@"; echo; }
ALPINE=generic_alpine-3.24.1-x86_64-bios-cloudinit-r0.qcow2

# MAC 决定 OpenWrt 角色（见 99-smartroute-lab），不要改
mk_wrt() { # vmid name mem image net0 [net1]
	api -X POST "$PVE/nodes/pve/qemu" --data-urlencode vmid=$1 --data-urlencode name=$2 --data-urlencode pool=lab \
		--data-urlencode memory=$3 --data-urlencode balloon=0 --data-urlencode cores=1 --data-urlencode cpuunits=50 \
		--data-urlencode ostype=l26 --data-urlencode scsihw=virtio-scsi-single --data-urlencode serial0=socket \
		--data-urlencode "scsi0=local-lvm:0,import-from=local:import/$4" --data-urlencode "net0=$5" \
		${6:+--data-urlencode "net1=$6"}
}

create() {
	mk_wrt 900 lab-isp  192 lab-iwrt-24.10.raw virtio=02:5A:00:00:01:00,bridge=labwan virtio=02:5A:00:00:01:01,bridge=vmbr0
	mk_wrt 901 lab-r24  256 lab-iwrt-24.10.raw virtio=02:5A:00:00:02:00,bridge=lablan virtio=02:5A:00:00:02:01,bridge=labwan
	mk_wrt 902 lab-r25  256 lab-iwrt-25.12.raw virtio=02:5A:00:00:02:00,bridge=lablan virtio=02:5A:00:00:02:01,bridge=labwan  # 与 r24 同 MAC，只开一台
	mk_wrt 903 lab-side 128 lab-iwrt-24.10.raw virtio=02:5A:00:00:04:00,bridge=lablan
	k=$(python3 -c "import urllib.parse,os;print(urllib.parse.quote(open(os.path.expanduser('~/.ssh/lab_ed25519.pub')).read().strip(), safe=''))")
	api -X POST "$PVE/nodes/pve/qemu" --data-urlencode vmid=904 --data-urlencode name=lab-hosts --data-urlencode pool=lab \
		--data-urlencode memory=256 --data-urlencode cores=1 --data-urlencode cpuunits=50 --data-urlencode ostype=l26 \
		--data-urlencode scsihw=virtio-scsi-single --data-urlencode "scsi0=local-lvm:0,import-from=local:import/$ALPINE" \
		--data-urlencode ide2=local-lvm:cloudinit --data-urlencode serial0=socket --data-urlencode vga=serial0 \
		--data-urlencode net0=virtio=02:5A:00:00:05:00,bridge=lablan --data-urlencode ciuser=alpine \
		--data-urlencode "sshkeys=$k" --data-urlencode ipconfig0=ip=dhcp,ip6=auto
}

ids=${2:-"900 901 903 904"}   # 默认跑 24.10；测 25.12 时: ./vms.sh stop 901 && ./vms.sh start 902
case "$1" in
	create) create ;;
	start)   for i in $ids; do api -X POST "$PVE/nodes/pve/qemu/$i/status/start"; done ;;
	stop)    for i in $ids; do api -X POST "$PVE/nodes/pve/qemu/$i/status/stop"; done ;;
	destroy) for i in ${2:-900 901 902 903 904}; do api -X POST "$PVE/nodes/pve/qemu/$i/status/stop" >/dev/null; sleep 3
	         api -X DELETE "$PVE/nodes/pve/qemu/$i?purge=1&destroy-unreferenced-disks=1"; done ;;
	*) echo "usage: $0 create|start|stop|destroy [vmid...]"; exit 1 ;;
esac
