package engine

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"

	"github.com/r1172464137/luci-app-smartroute/internal/bpf"
)

// 域名记录持久化：停止时把未过期的记录存到闪存，启动时恢复（路由器重启后域名规则立即可用，不必等设备重新解析）。
// eBPF 里的时间是开机以来的单调时间，存盘时换算成到期的墙上时间。文件开头是格式版本，表结构变了旧文件直接忽略
const (
	dnsCache = "/etc/smartroute/dns.cache"
	dnsMagic = "SRDNS2\n" // 2：记录按设备（MAC）区分
)

type dnsRec struct {
	Key   bpf.SrDnsKey
	Val   bpf.SrDnsVal
	Until int64 // 到期时间（Unix 秒）
}

func monoNow() uint64 {
	var ts unix.Timespec
	unix.ClockGettime(unix.CLOCK_MONOTONIC, &ts)
	return uint64(ts.Nano())
}

func (e *Engine) saveDNS() {
	now, wall, keep := monoNow(), time.Now().Unix(), uint64(e.s.DNSKeep)
	os.MkdirAll(filepath.Dir(dnsCache), 0o755)
	tmp := dnsCache + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		log.Printf("save domain records: %v", err)
		return
	}
	w := bufio.NewWriter(f)
	w.WriteString(dnsMagic)
	var r dnsRec
	n := 0
	it := e.objs.SrDns.Iterate()
	for it.Next(&r.Key, &r.Val) {
		ttl, age := max(uint64(r.Val.Ttl), keep), (now-r.Val.SeenNs)/1e9
		if now < r.Val.SeenNs || age >= ttl {
			continue
		}
		r.Until = wall + int64(ttl-age)
		binary.Write(w, binary.LittleEndian, &r)
		n++
	}
	if err := errors.Join(w.Flush(), f.Close()); err != nil {
		os.Remove(tmp)
		log.Printf("save domain records: %v", err)
		return
	}
	os.Rename(tmp, dnsCache)
	log.Printf("saved %d domain records", n)
}

// loadDNS 恢复未到期的记录：记录时间设为现在，有效期设为剩余时间
func (e *Engine) loadDNS() int {
	f, err := os.Open(dnsCache)
	if err != nil {
		return 0
	}
	defer f.Close()
	rd := bufio.NewReader(f)
	head := make([]byte, len(dnsMagic))
	if _, err := io.ReadFull(rd, head); err != nil || string(head) != dnsMagic {
		return 0
	}
	now, wall, n := monoNow(), time.Now().Unix(), 0
	var r dnsRec
	for {
		if err := binary.Read(rd, binary.LittleEndian, &r); err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("domain record file damaged, restored %d records", n)
			}
			return n
		}
		if r.Until <= wall || r.Val.Len > uint32(len(r.Val.Name)) {
			continue
		}
		r.Val.SeenNs, r.Val.Ttl = now, uint32(r.Until-wall)
		if e.objs.SrDns.Put(r.Key, r.Val) == nil {
			n++
		}
	}
}
