// smartroute：智能分流后台。
//
//	smartroute run                 常驻（由 procd 启动）：挂载数据面、应用配置；SIGHUP 重新加载，SIGTERM 清理后退出
//	smartroute status              输出运行状态（JSON）
//	smartroute update              立即更新规则数据文件，有变化时通知常驻进程重新加载
//	smartroute trace <设备> <目标>  流量走向测试：设备为 MAC 或 IPv4，目标为域名或 IP（JSON）
//	smartroute dns [域名或 IP]      查询域名记录（JSON）
//	smartroute cats                数据文件里的类别（JSON），供编辑规则组时插入
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/cilium/ebpf"
	"github.com/vishvananda/netlink"

	"github.com/r1172464137/luci-app-smartroute/internal/bpf"
	"github.com/r1172464137/luci-app-smartroute/internal/engine"
	"github.com/r1172464137/luci-app-smartroute/internal/rules"
	"github.com/r1172464137/luci-app-smartroute/internal/uci"
)

const pidFile = "/var/run/smartroute.pid"

func main() {
	log.SetFlags(0)
	args := append(os.Args[1:], "", "", "")
	var err error
	switch args[0] {
	case "run":
		err = run()
	case "status":
		err = status()
	case "update":
		err = update()
	case "trace":
		err = trace(args[1], args[2])
	case "dns":
		err = dns(args[1])
	case "cats":
		err = cats()
	default:
		fmt.Fprintln(os.Stderr, "usage: smartroute run | status | update | trace <device> <target> | dns [domain or IP] | cats")
		os.Exit(2)
	}
	if err != nil {
		log.Print(err)
		os.Exit(1)
	}
}

func load() (*engine.Plan, error) {
	secs, err := uci.Load("smartroute")
	if err != nil {
		return nil, err
	}
	fw, _ := uci.Load("firewall") // 只用于检查接口出口的地址伪装，读不到就不检查
	return engine.Compile(secs, engine.DataDir, fw)
}

func printJSON(v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(b))
}

func run() error {
	p, err := load()
	if err != nil {
		return err
	}
	if !p.S.Enabled {
		log.Print("not enabled")
		return nil
	}
	e, err := engine.New()
	if err != nil {
		return err
	}
	os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0o644)
	defer func() { // 清理完再删 pid 文件：init 脚本据此判断进程已退出
		e.Close()
		os.Remove(pidFile)
	}()
	if err := e.Apply(p); err != nil {
		return err
	}

	var cur atomic.Pointer[engine.Plan]
	cur.Store(p)
	reload := make(chan struct{}, 1)
	go updater(&cur, e.DownloadMark, func() {
		select {
		case reload <- struct{}{}:
		default:
		}
	})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	refresh := time.NewTicker(30 * time.Second)
	healthTick := time.NewTicker(time.Second)
	// 接口与地址变化（netifd 重载、WAN 重拨、前缀变化）：攒 2 秒后重新挂载并更新路由与保护网段
	done := make(chan struct{})
	defer close(done)
	addrs, links := make(chan netlink.AddrUpdate, 64), make(chan netlink.LinkUpdate, 64)
	if err := netlink.AddrSubscribe(addrs, done); err != nil {
		log.Printf("watch address changes: %v", err)
	}
	if err := netlink.LinkSubscribe(links, done); err != nil {
		log.Printf("watch interface changes: %v", err)
	}
	var rewire <-chan time.Time
	e.HealthTick(p)
	for {
		select {
		case s := <-sig:
			if s != syscall.SIGHUP {
				log.Print("stopping")
				return nil
			}
		case <-reload:
		case <-refresh.C:
			if err := e.Refresh(p); err != nil {
				log.Printf("refresh: %v", err)
			}
			continue
		case <-healthTick.C:
			e.HealthTick(p)
			continue
		case r := <-e.Probes():
			if err := e.HealthResult(p, r); err != nil {
				log.Printf("failover: %v", err)
			}
			continue
		case _, ok := <-addrs:
			if !ok {
				addrs = nil
			}
			rewire = time.After(2 * time.Second)
			continue
		case u, ok := <-links:
			if !ok {
				links = nil
			} else if slices.Contains(p.S.Ifaces, u.Attrs().Name) {
				rewire = time.After(2 * time.Second)
			}
			continue
		case <-rewire:
			rewire = nil
			if err := e.Rewire(p); err != nil {
				log.Printf("rewire after interface change: %v", err)
			}
			continue
		}
		np, err := load()
		if err != nil {
			log.Printf("read configuration, keeping the current state: %v", err)
			continue
		}
		if !np.S.Enabled {
			return nil
		}
		if err := e.Apply(np); err != nil {
			log.Printf("apply configuration: %v", err)
			continue
		}
		p = np
		cur.Store(p)
	}
}

func datMissing() bool {
	for _, f := range []string{"geosite.dat", "geoip.dat"} {
		if _, err := os.Stat(filepath.Join(engine.DataDir, f)); err != nil {
			return true
		}
	}
	return false
}

// updater：每天 update_hour 点更新数据文件；缺文件时立即下载，失败每 30 分钟重试。后台进行，不阻塞分流
func updater(cur *atomic.Pointer[engine.Plan], mark func() uint32, trigger func()) {
	var lastTry time.Time
	lastDay := ""
	for {
		p, now := cur.Load(), time.Now()
		day := now.Format("2006-01-02")
		scheduled := p.S.UpdateHour >= 0 && now.Hour() == p.S.UpdateHour && day != lastDay
		if scheduled || (datMissing() && now.Sub(lastTry) > 30*time.Minute) {
			lastTry = now
			if scheduled {
				lastDay = day
			}
			changed, errs := engine.FetchAll(p.S, engine.DataDir, mark())
			for _, err := range errs {
				log.Print(err)
			}
			if changed {
				log.Print("rule data files updated")
				trigger()
			}
		}
		time.Sleep(time.Minute)
	}
}

func update() error {
	p, err := load()
	if err != nil {
		return err
	}
	changed, errs := engine.FetchAll(p.S, engine.DataDir, p.ExitMark(p.S.DownloadExit))
	for _, err := range errs {
		log.Print(err)
	}
	fmt.Printf("changed=%v\n", changed)
	if changed {
		if b, err := os.ReadFile(pidFile); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				syscall.Kill(pid, syscall.SIGHUP)
			}
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%d file(s) failed to update", len(errs))
	}
	return nil
}

func trace(device, target string) error {
	if device == "" || target == "" {
		return fmt.Errorf("usage: smartroute trace <device MAC or IPv4> <domain or IP>")
	}
	p, err := load()
	if err != nil {
		return err
	}
	t, err := engine.RunTrace(p, device, target)
	if err != nil {
		return err
	}
	printJSON(t)
	return nil
}

func dns(q string) error {
	p, err := load()
	if err != nil {
		return err
	}
	recs, err := engine.DNSRecords(q, "", p.S.DNSKeep)
	if err != nil {
		return err
	}
	if recs == nil {
		recs = []engine.DNSRecord{}
	}
	printJSON(recs)
	return nil
}

func cats() error {
	out := map[string]any{}
	for _, f := range []string{"geosite", "geoip"} {
		path := filepath.Join(engine.DataDir, f+".dat")
		codes, err := rules.Codes(path)
		if codes == nil {
			codes = []string{}
		}
		info := map[string]any{"codes": codes}
		if st, e := os.Stat(path); e == nil && err == nil {
			info["size"], info["mtime"] = st.Size(), st.ModTime().Unix()
		}
		out[f] = info
	}
	printJSON(out)
	return nil
}

func count(m *ebpf.Map) int {
	var k, v []byte
	n := 0
	for it := m.Iterate(); it.Next(&k, &v); {
		n++
	}
	return n
}

func status() error {
	out := map[string]any{"running": false}
	if b, err := os.ReadFile(engine.StateFile); err == nil {
		var st struct{ Policies []string }
		if json.Unmarshal(b, &st) == nil {
			out["state"] = json.RawMessage(b)
			out["running"] = true
			hits := map[string]uint64{}
			if m, err := bpf.Pinned("sr_hits"); err == nil {
				for i, id := range st.Policies {
					var per []uint64
					if m.Lookup(uint32(i), &per) == nil {
						for _, v := range per {
							hits[id] += v
						}
					}
				}
				m.Close()
			}
			out["hits"] = hits
		}
	}
	stats := map[string]any{}
	if m, err := bpf.Pinned("sr_stats"); err == nil {
		for i, n := range []string{"dns_responses", "dns_records", "dns_failed", "new_flows", "steered_flows", "aaaa_blocked", "dns_steered"} {
			var v uint64
			if m.Lookup(uint32(i), &v) == nil {
				stats[n] = v
			}
		}
		m.Close()
	}
	for name, key := range map[string]string{"sr_dns": "dns_entries", "sr_conn": "conn_entries"} {
		if m, err := bpf.Pinned(name); err == nil {
			stats[key] = count(m)
			m.Close()
		}
	}
	out["stats"] = stats
	printJSON(out)
	return nil
}
