package main

import (
	"os/exec"
)

var tcInited bool

func tcLazyInit() {
	if tcInited {
		return
	}
	tcInited = true
	exec.Command("modprobe", "sch_htb", "act_mirred", "ifb").Run()
	exec.Command("ip", "link", "add", "dev", "ifb0", "type", "ifb").Run()
	exec.Command("ip", "link", "set", "dev", "ifb0", "up").Run()
	exec.Command("tc", "qdisc", "add", "dev", lanIface, "root", "handle", "1:0", "htb", "default", "1").Run()
	exec.Command("tc", "class", "add", "dev", lanIface, "parent", "1:0", "classid", "1:1", "htb", "rate", "1000mbit", "ceil", "1000mbit").Run()
	exec.Command("tc", "qdisc", "add", "dev", "ifb0", "root", "handle", "1:0", "htb", "default", "1").Run()
	exec.Command("tc", "class", "add", "dev", "ifb0", "parent", "1:0", "classid", "1:1", "htb", "rate", "1000mbit", "ceil", "1000mbit").Run()
	exec.Command("tc", "qdisc", "add", "dev", lanIface, "handle", "ffff:", "ingress").Run()
	exec.Command("tc", "filter", "add", "dev", lanIface, "parent", "ffff:", "prio", "2",
		"protocol", "all", "u32", "match", "u32", "0", "0", "flowid", "1:1", "action", "mirred", "egress", "redirect", "dev", "ifb0").Run()
}
