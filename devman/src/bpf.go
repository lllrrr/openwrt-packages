package main

import (
	"fmt"
	"log"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/net/bpf"
)

// sockFilter struct matching kernel's sock_filter
type sockFilter struct {
	Code uint16
	Jt   uint8
	Jf   uint8
	K    uint32
}
type sockFprog struct {
	Len    uint16
	Pad    uint16
	Filter *sockFilter
}

// dhcpBPFLoop opens an AF_PACKET socket with BPF filter for DHCP,
// parses REQUEST/ACK packets and extracts hostname, vendor_class, opt55.
// Unlike dnsmasqLeaseLoop which polls the lease file, this captures real-time
// DHCP events directly from the kernel.
func dhcpBPFLoop() {
	prog, err := bpf.Assemble([]bpf.Instruction{
		bpf.LoadAbsolute{Off: 9, Size: 1},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 17, SkipTrue: 0, SkipFalse: 6},
		bpf.LoadAbsolute{Off: 20, Size: 2},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 67, SkipTrue: 3, SkipFalse: 0},
		bpf.LoadAbsolute{Off: 22, Size: 2},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 67, SkipTrue: 1, SkipFalse: 0},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 68, SkipTrue: 0, SkipFalse: 1},
		bpf.RetConstant{Val: 65535},
		bpf.RetConstant{Val: 0},
	})
	if err != nil {
		log.Printf("DHCP_BPF: assemble err=%v", err)
		return
	}

	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_DGRAM, int(htons(syscall.ETH_P_IP)))
	if err != nil {
		log.Printf("DHCP_BPF: socket err=%v", err)
		return
	}
	defer syscall.Close(fd)

	// Attach BPF
	insns := make([]sockFilter, len(prog))
	for i, r := range prog {
		insns[i] = sockFilter{Code: r.Op, Jt: r.Jt, Jf: r.Jf, K: r.K}
	}
	var fprog sockFprog
	fprog.Len = uint16(len(insns))
	fprog.Filter = &insns[0]
	_, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, uintptr(fd),
		uintptr(syscall.SOL_SOCKET), uintptr(syscall.SO_ATTACH_FILTER),
		uintptr(unsafe.Pointer(&fprog)), uintptr(unsafe.Sizeof(fprog)), 0)
	if e != 0 {
		log.Printf("DHCP_BPF: SO_ATTACH_FILTER err=%v", e)
		return
	}

	log.Printf("DHCP_BPF: started")

	buf := make([]byte, 4096)
	for {
		tv := syscall.Timeval{Sec: 5}
		syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)

		n, _, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			continue
		}
		// SOCK_DGRAM: offset 0 = IP start, IP hdr=20 + UDP hdr=8 + DHCP
		dhcpOff := 20 + 8
		// Check DHCP magic cookie: 0x63825363
		if n < dhcpOff+244 || buf[dhcpOff+236] != 0x63 || buf[dhcpOff+237] != 0x82 ||
			buf[dhcpOff+238] != 0x53 || buf[dhcpOff+239] != 0x63 {
			continue
		} // invalid/missing magic

		// Validate BOOTP: op=1/2, htype=1(Ethernet), hlen=6(MAC)
		op := buf[dhcpOff]
		if op != 1 && op != 2 {
			continue
		}
		if buf[dhcpOff+1] != 1 || buf[dhcpOff+2] != 6 {
			continue
		}

		// Client MAC: must be 6 valid hex pairs
		mac := fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
			buf[dhcpOff+28], buf[dhcpOff+29], buf[dhcpOff+30],
			buf[dhcpOff+31], buf[dhcpOff+32], buf[dhcpOff+33])
		if len(mac) == 17 && mac[2] == ':' && mac[5] == ':' {
			// valid MAC format
		} else {
			continue
		}

		// IP: yiaddr for REPLY, ciaddr for REQUEST
		ip := fmt.Sprintf("%d.%d.%d.%d",
			buf[dhcpOff+20], buf[dhcpOff+21], buf[dhcpOff+22], buf[dhcpOff+23])
		if op == 1 {
			ciaddr := fmt.Sprintf("%d.%d.%d.%d",
				buf[dhcpOff+16], buf[dhcpOff+17], buf[dhcpOff+18], buf[dhcpOff+19])
			if ciaddr != "0.0.0.0" {
				ip = ciaddr
			}
		}

		if ip == "0.0.0.0" {
			continue
		}

		// Parse options
		var msgType int
		var hostname, vendorClass string
		var opt55 []byte
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
					hostname = string(buf[optPos+2 : optPos+2+optLen])
				}
			case 60:
				if optLen > 0 {
					vendorClass = printable(buf[optPos+2 : optPos+2+optLen])
				}
			case 55:
				if optLen > 0 {
					opt55 = make([]byte, optLen)
					copy(opt55, buf[optPos+2:optPos+2+optLen])
				}
			}
			optPos += 2 + optLen
		}

		if hostname == "" && vendorClass == "" {
			continue
		}

		log.Printf("DHCP_BPF: %s %s %s type=%d host=%q vc=%q", mac, ip,
			map[bool]string{true: "RPL", false: "REQ"}[op == 2], msgType, hostname, vendorClass)

		// ACK (type=5) from server → confirmed lease
		if op == 2 && msgType == 5 {
			upsertDevice(ip, mac, hostname, vendorClass, "")
		}
		// REQUEST (type=3) from client → fingerprint data
		if op == 1 && msgType == 3 && vendorClass != "" {
			upsertDevice(ip, mac, hostname, vendorClass, "")
		}
	}
}

func printable(b []byte) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r > 126 {
			return '.'
		}
		return r
	}, string(b))
}

func htons(v uint16) uint16 { return (v>>8)&0xff | (v&0xff)<<8 }
