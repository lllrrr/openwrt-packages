#!/bin/sh
# tc rate limiting - upload (ingress police) / download (htb egress)
CID=$2; IP=$3; RATE=${4:-0}; IF=br-lan

# Auto-detect LAN subnet from scope link route
LAN_NET=$(ip route show dev $IF scope link 2>/dev/null | awk '{print $1; exit}')
[ -z "$LAN_NET" ] && LAN_NET="192.168.5.0/24"

case "$1" in
  init)
    tc qdisc add dev $IF root handle 1: htb default 30 2>/dev/null
    tc qdisc add dev $IF handle ffff: ingress 2>/dev/null
    ;;
  set)
    # Upload: police on ingress, LAN traffic passes through
    tc filter del dev $IF parent ffff: prio $CID 2>/dev/null
    tc filter del dev $IF parent ffff: prio 1$CID 2>/dev/null
    # LAN traffic → pass, no limit
    tc filter add dev $IF parent ffff: prio $CID u32 match ip src $IP match ip dst $LAN_NET action pass 2>/dev/null
    # WAN traffic → police
    tc filter add dev $IF parent ffff: prio 1$CID u32 match ip src $IP police rate ${RATE}kbit burst 10k drop 2>/dev/null
    ;;
  del)
    tc filter del dev $IF parent ffff: prio $CID 2>/dev/null
    tc filter del dev $IF parent ffff: prio 1$CID 2>/dev/null
    ;;
  setdn)
    # Download: htb egress on dst IP
    DNID="1${CID}"
    tc class add dev $IF parent 1: classid 1:$DNID htb rate ${RATE}kbit ceil ${RATE}kbit burst 1600 cburst 1600 2>/dev/null ||
    tc class change dev $IF parent 1: classid 1:$DNID htb rate ${RATE}kbit ceil ${RATE}kbit burst 1600 cburst 1600 2>/dev/null
    tc filter replace dev $IF parent 1: prio 1 u32 match ip dst $IP flowid 1:$DNID 2>/dev/null
    ;;
  deldn)
    DNID="1${CID}"
    tc filter del dev $IF parent 1: prio 1 u32 match ip dst $IP flowid 1:$DNID 2>/dev/null
    tc class del dev $IF parent 1: classid 1:$DNID 2>/dev/null
    ;;
  clean)
    tc qdisc del dev $IF root 2>/dev/null
    tc qdisc del dev $IF ingress 2>/dev/null
    nft delete chain ip devman limit_up 2>/dev/null
    nft delete chain ip devman limit_up_init 2>/dev/null
    ;;
esac
