package discover

import (
	"log"
	"os/exec"
	"strings"
	"sync"
	"time"
)

var (
	ArpStates = map[string]string{}
	ArpMu     sync.RWMutex
)

func NeightLoop() {
	log.Printf("NEIGH: started")
	exec.Command("sysctl", "-w", "net.ipv4.neigh.default.base_reachable_time_ms=15000").Run()
	exec.Command("sysctl", "-w", "net.ipv4.neigh.default.gc_stale_time=30").Run()
	for {
		out, _ := exec.Command("/sbin/ip", "neigh", "show").Output()
		ArpMu.Lock()
		ArpStates = map[string]string{}
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) < 4 {
				continue
			}
			ip := fields[0]
			if strings.HasPrefix(ip, "169.254") || strings.HasPrefix(ip, "127.") {
				continue
			}
			if len(fields) == 4 && fields[3] == "FAILED" {
				ArpStates[ip] = "FAILED"
				continue
			}
			if len(fields) < 6 {
				continue
			}
			mac, state := fields[4], fields[5]
			if mac == "00:00:00:00:00:00" || mac == "incomplete" {
				continue
			}
			ArpStates[ip] = state
			if state != "FAILED" {
				UpsertDeviceNoSeen(ip, mac, "", "")
			}
		}
		ArpMu.Unlock()
		time.Sleep(15 * time.Second)
	}
}
