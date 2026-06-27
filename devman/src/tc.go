package main

import (
	"log"
	"os/exec"
)

var tcInited bool

func tcLazyInit() {
	if tcInited {
		return
	}
	tcInited = true
	
	if err := exec.Command("modprobe", "sch_htb", "act_mirred", "ifb").Run(); err != nil {
		log.Printf("TC: modprobe failed: %v", err)
	}
	if err := exec.Command("ip", "link", "add", "dev", "ifb0", "type", "ifb").Run(); err != nil {
		log.Printf("TC: ip link add ifb0 failed: %v", err)
	}
	if err := exec.Command("ip", "link", "set", "dev", "ifb0", "up").Run(); err != nil {
		log.Printf("TC: ip link set ifb0 up failed: %v", err)
	}
	if err := exec.Command("tc", "qdisc", "add", "dev", lanIface, "root", "handle", "1:0", "htb", "default", "1").Run(); err != nil {
		log.Printf("TC: qdisc add %s root failed: %v", lanIface, err)
	}
	if err := exec.Command("tc", "class", "add", "dev", lanIface, "parent", "1:0", "classid", "1:1", "htb", "rate", "1000mbit", "ceil", "1000mbit").Run(); err != nil {
		log.Printf("TC: class add %s failed: %v", lanIface, err)
	}
	if err := exec.Command("tc", "qdisc", "add", "dev", "ifb0", "root", "handle", "1:0", "htb", "default", "1").Run(); err != nil {
		log.Printf("TC: qdisc add ifb0 root failed: %v", err)
	}
	if err := exec.Command("tc", "class", "add", "dev", "ifb0", "parent", "1:0", "classid", "1:1", "htb", "rate", "1000mbit", "ceil", "1000mbit").Run(); err != nil {
		log.Printf("TC: class add ifb0 failed: %v", err)
	}
	if err := exec.Command("tc", "qdisc", "add", "dev", lanIface, "handle", "ffff:", "ingress").Run(); err != nil {
		log.Printf("TC: qdisc add %s ingress failed: %v", lanIface, err)
	}
	if err := exec.Command("tc", "filter", "add", "dev", lanIface, "parent", "ffff:", "prio", "2",
		"protocol", "all", "u32", "match", "u32", "0", "0", "flowid", "1:1", "action", "mirred", "egress", "redirect", "dev", "ifb0").Run(); err != nil {
		log.Printf("TC: filter add %s failed: %v", lanIface, err)
	}
}
