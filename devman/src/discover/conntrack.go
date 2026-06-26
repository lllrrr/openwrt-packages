package discover

import (
	"log"
	"os/exec"
	"strings"
	"time"
)

func ConntrackLoop() {
	log.Printf("CONNTRACK: started")
	for {
		out, _ := exec.Command("/usr/sbin/conntrack", "-L", "-o", "id").Output()
		for _, line := range strings.Split(string(out), "\n") {
			srcIdx := strings.Index(line, "src=")
			if srcIdx < 0 {
				continue
			}
			src := strings.SplitN(line[srcIdx+4:], " ", 2)[0]
			dstIdx := strings.Index(line, "dst=")
			if dstIdx < 0 {
				continue
			}
			dst := strings.SplitN(line[dstIdx+4:], " ", 2)[0]
			if !IsLAN(src) && IsLAN(dst) {
				if dst != "" && !strings.HasPrefix(dst, "127.") {
					UpsertDevice(dst, "", "", "", "")
				}
			}
		}
		time.Sleep(15 * time.Second)
	}
}
