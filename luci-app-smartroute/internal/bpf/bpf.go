// Package bpf 加载数据面（ebpf/smartroute.bpf.c，由 bpf2go 编译后嵌入程序）。
package bpf

//go:generate go run github.com/cilium/ebpf/cmd/bpf2go -tags linux Sr ../../ebpf/smartroute.bpf.c -- -I/usr/include/x86_64-linux-gnu

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
)

// PinDir 固定表的目录，供 status 等其他进程读取
const PinDir = "/sys/fs/bpf/smartroute"

// Open 加载对象，表固定到 PinDir；表结构变了（升级）就清掉旧表重建
func Open() (*SrObjects, error) {
	if err := os.MkdirAll(PinDir, 0o700); err != nil {
		return nil, err
	}
	var objs SrObjects
	opts := &ebpf.CollectionOptions{Maps: ebpf.MapOptions{PinPath: PinDir}}
	err := LoadSrObjects(&objs, opts)
	if errors.Is(err, ebpf.ErrMapIncompatible) {
		Remove()
		os.MkdirAll(PinDir, 0o700)
		err = LoadSrObjects(&objs, opts)
	}
	if err != nil {
		var ve *ebpf.VerifierError
		if errors.As(err, &ve) {
			return nil, fmt.Errorf("加载 eBPF 失败：%+v", ve)
		}
		return nil, fmt.Errorf("加载 eBPF 失败：%w", err)
	}
	return &objs, nil
}

// Attach 挂到接口的 tcx ingress / egress。link 不固定：进程退出即卸载，网络回到直连
func Attach(objs *SrObjects, ifname string) ([]link.Link, error) {
	ifc, err := net.InterfaceByName(ifname)
	if err != nil {
		return nil, err
	}
	in, err := link.AttachTCX(link.TCXOptions{Interface: ifc.Index, Program: objs.SrIngress, Attach: ebpf.AttachTCXIngress})
	if err != nil {
		return nil, fmt.Errorf("挂载 ingress：%w", err)
	}
	out, err := link.AttachTCX(link.TCXOptions{Interface: ifc.Index, Program: objs.SrEgress, Attach: ebpf.AttachTCXEgress})
	if err != nil {
		in.Close()
		return nil, fmt.Errorf("挂载 egress：%w", err)
	}
	return []link.Link{in, out}, nil
}

func Pinned(name string) (*ebpf.Map, error) {
	return ebpf.LoadPinnedMap(filepath.Join(PinDir, name), &ebpf.LoadPinOptions{ReadOnly: true})
}

func Remove() { os.RemoveAll(PinDir) }
