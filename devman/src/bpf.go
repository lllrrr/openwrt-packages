package main

import (
	"crypto/sha256"
	"fmt"
	"log"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

func htons(v uint16) uint16 { return (v>>8)&0xff | (v<<8)&0xff00 }

func dhcpBPFLoop() {
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_DGRAM, int(htons(syscall.ETH_P_IP)))
	if err != nil {
		log.Printf("DHCP_BPF: socket err=%v", err)
		return
	}
	defer syscall.Close(fd)

	var ifIdx int
	ifi, _ := syscall.NetlinkRIB(syscall.RTM_GETLINK, syscall.AF_UNSPEC)
	if ifi != nil {
		msgs, _ := syscall.ParseNetlinkMessage(ifi)
		for _, m := range msgs {
			if m.Header.Type == syscall.RTM_NEWLINK {
				imsg := (*syscall.IfInfomsg)(unsafe.Pointer(&m.Data[0]))
				name := strings.TrimRight(string(m.Data[syscall.SizeofIfInfomsg:]), "\x00")
				if name == lanIface {
					ifIdx = int(imsg.Index)
					break
				}
			}
		}
	}
	if ifIdx == 0 {
		data, rerr := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/ifindex", lanIface))
		if rerr == nil {
			ifIdx, _ = strconv.Atoi(strings.TrimSpace(string(data)))
		}
	}
	if ifIdx == 0 {
		log.Printf("DHCP_BPF: cannot find %s", lanIface)
		return
	}

	addr := syscall.SockaddrLinklayer{Protocol: htons(syscall.ETH_P_IP), Ifindex: ifIdx}
	if err := syscall.Bind(fd, &addr); err != nil {
		log.Printf("DHCP_BPF: bind %s err=%v", lanIface, err)
		return
	}
	log.Printf("DHCP_BPF: bound to %s (idx=%d)", lanIface, ifIdx)

	tv := syscall.Timeval{Sec: 5}
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		log.Printf("DHCP_BPF: rcvtimeo err=%v", err)
	}

	buf := make([]byte, 4096)
	var pkts int64
	lastLog := time.Now()
	for {
		n, _, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			if time.Since(lastLog) > 30*time.Second {
				log.Printf("DHCP_BPF: alive, %d DHCP packets captured so far", pkts)
				lastLog = time.Now()
			}
			continue
		}
		pkts++
		if n < 28 {
			if pkts <= 5 { log.Printf("DHCP_BPF: pkt#%d too short n=%d", pkts, n) }
			continue
		}
		sport := uint16(buf[20])<<8 | uint16(buf[21])
		dport := uint16(buf[22])<<8 | uint16(buf[23])
		if pkts <= 5 {
			log.Printf("DHCP_BPF: pkt#%d len=%d proto=%d sport=%d dport=%d [%02x%02x%02x%02x]", pkts, n, buf[9], sport, dport, buf[0], buf[1], buf[2], buf[3])
		}
		if buf[9] != 17 {
			if pkts <= 5 { log.Printf("DHCP_BPF:   -> skip: proto=%d != 17", buf[9]) }
			continue
		}
		if sport != 67 && sport != 68 && dport != 67 && dport != 68 {
			if pkts <= 5 { log.Printf("DHCP_BPF:   -> skip: port %d/%d not DHCP", sport, dport) }
			continue
		}

		dhcpOff := 28
		if n < dhcpOff+244 {
			continue
		}
		if buf[dhcpOff+236] != 0x63 || buf[dhcpOff+237] != 0x82 ||
			buf[dhcpOff+238] != 0x53 || buf[dhcpOff+239] != 0x63 {
			continue
		}
		op := int(buf[dhcpOff])
		if op != 1 && op != 2 {
			continue
		}
		if buf[dhcpOff+1] != 1 || buf[dhcpOff+2] != 6 {
			continue
		}
		mac := fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
			buf[dhcpOff+28], buf[dhcpOff+29], buf[dhcpOff+30],
			buf[dhcpOff+31], buf[dhcpOff+32], buf[dhcpOff+33])
		if len(mac) != 17 || mac[2] != ':' {
			continue
		}
		ip := fmt.Sprintf("%d.%d.%d.%d",
			buf[dhcpOff+20], buf[dhcpOff+21], buf[dhcpOff+22], buf[dhcpOff+23])
		if op == 1 {
			ciaddr := fmt.Sprintf("%d.%d.%d.%d",
				buf[dhcpOff+16], buf[dhcpOff+17], buf[dhcpOff+18], buf[dhcpOff+19])
			if ciaddr != "0.0.0.0" {
				ip = ciaddr
			}
		}

		var msgType int
		var hostname, vendorClass string
		var opt55Codes []byte
		optPos := dhcpOff + 240
		for optPos < n-1 {
			code := int(buf[optPos])
			if code == 255 {
				break
			}
			if code == 0 {
				optPos++
				continue
			}
			optLen := int(buf[optPos+1])
			if optPos+2+optLen > n {
				break
			}
			switch code {
			case 53:
				if optLen >= 1 {
					msgType = int(buf[optPos+2])
				}
			case 12:
				if optLen > 0 {
					hostname = printable(buf[optPos+2 : optPos+2+optLen])
				}
			case 60:
				if optLen > 0 {
					vendorClass = printable(buf[optPos+2 : optPos+2+optLen])
				}
			case 55:
				opt55Codes = append(opt55Codes[:0], buf[optPos+2:optPos+2+optLen]...)
			}
			optPos += 2 + optLen
		}

		var opt55Hash string
		if len(opt55Codes) > 0 {
			sorted := make([]byte, len(opt55Codes))
			copy(sorted, opt55Codes)
			sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
			h := sha256.New()
			h.Write(sorted)
			opt55Hash = fmt.Sprintf("%x", h.Sum(nil))[:16]
		}

		if ip == "0.0.0.0" && msgType != 1 {
			continue
		}

		if hostname != "" || vendorClass != "" || opt55Hash != "" {
			var codes []string
			for _, c := range opt55Codes {
				codes = append(codes, strconv.Itoa(int(c)))
			}
			log.Printf("DHCP_BPF: %s %s %s type=%d host=%q vc=%q opt55=%s hash=%s", mac, ip,
				map[bool]string{true: "RPL", false: "REQ"}[op == 2], msgType, hostname, vendorClass,
				strings.Join(codes, ","), opt55Hash)
		}

		mu.Lock()
		// Capture any DHCP packet with useful data
		if hostname != "" || vendorClass != "" || opt55Hash != "" {
			upsertDevice(ip, mac, hostname, vendorClass, opt55Hash)
		}
		mu.Unlock()
	}
}

func printable(b []byte) string {
	var out []byte
	for _, c := range b {
		if c >= 32 && c < 127 {
			out = append(out, c)
		}
	}
	return string(out)
}
