package main

import (
	"os"
	"strings"
	"sync"
	"time"
)

var (
	speedMu    sync.RWMutex
	speedIn    = map[string]uint64{}
	speedOut   = map[string]uint64{}
	spPrevUp   = map[string]uint64{}
	spPrevDown = map[string]uint64{}
	spFirst    = map[string]bool{}
	spLastTime time.Time
	spLastGC   time.Time
)

func speedLoop() {
	for {
		calcSpeed()
		time.Sleep(5 * time.Second)
	}
}

func calcSpeed() {
	data, err := os.ReadFile("/proc/net/nf_conntrack")
	if err != nil {
		return
	}
	curUp := map[string]uint64{}
	curDown := map[string]uint64{}
	for _, line := range strings.Split(string(data), "\n") {
		// Format: ... src=IP dst=IP ... bytes=N ... [mark]
		sIdx := strings.Index(line, "src=")
		if sIdx < 0 {
			continue
		}
		rest := line[sIdx+4:]
		fields := strings.Fields(rest)
		if len(fields) < 1 {
			continue
		}
		src := fields[0]
		if !isLAN(src) || src == "127.0.0.1" {
			continue
		}
		fb := strings.Index(line, "bytes=")
		lb := strings.LastIndex(line, "bytes=")
		if fb < 0 {
			continue
		}
		up, _ := atoui(strings.SplitN(line[fb+6:], " ", 2)[0])
		curUp[src] += up
		if lb > fb {
			dn, _ := atoui(strings.SplitN(line[lb+6:], " ", 2)[0])
			curDown[src] += dn
		}
	}
	interval := float64(time.Since(spLastTime).Seconds())
	if interval < 1 || spLastTime.IsZero() {
		interval = 1
	}
	spLastTime = time.Now()
	allIPs := map[string]bool{}
	for ip := range curUp {
		allIPs[ip] = true
	}
	for ip := range curDown {
		allIPs[ip] = true
	}

	now := time.Now().Unix()
	speedMu.Lock()
	for ip := range allIPs {
		if !spFirst[ip] {
			spFirst[ip] = true
			spPrevUp[ip] = curUp[ip]
			spPrevDown[ip] = curDown[ip]
			continue
		}
		var up, dn uint64
		if curUp[ip] > spPrevUp[ip] {
			up = uint64(float64(curUp[ip]-spPrevUp[ip]) / interval * 8)
		}
		if curDown[ip] > spPrevDown[ip] {
			dn = uint64(float64(curDown[ip]-spPrevDown[ip]) / interval * 8)
		}
		spPrevUp[ip] = curUp[ip]
		spPrevDown[ip] = curDown[ip]
		// Show real speed when significant; keep decaying if traffic is tiny
		if up > 0 && up > speedIn[ip]/3 {
			speedIn[ip] = up
		} else if up == 0 {
			speedIn[ip] = uint64(float64(speedIn[ip]) * 0.7)
		}
		if dn > 0 && dn > speedOut[ip]/3 {
			speedOut[ip] = dn
		} else if dn == 0 {
			speedOut[ip] = uint64(float64(speedOut[ip]) * 0.7)
		}
		// Update last_seen for any IP with traffic
		if up > 0 || dn > 0 {
			db.Model(&Device{}).Where("ipv4 = ?", ip).Update("last_seen", now)
		}
	}
	if time.Since(spLastGC) > 10*time.Minute {
		for k := range spPrevUp {
			if _, ok := curUp[k]; !ok {
				delete(spPrevUp, k)
				delete(spPrevDown, k)
				delete(spFirst, k)
				delete(speedIn, k)
				delete(speedOut, k)
			}
		}
		spLastGC = time.Now()
	}
	speedMu.Unlock()
}

func getSpeed(ip string) (in, out uint64) {
	speedMu.RLock()
	defer speedMu.RUnlock()
	return speedIn[ip], speedOut[ip]
}

func atoui(s string) (uint64, error) {
	var n uint64
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + uint64(c-'0')
	}
	return n, nil
}
