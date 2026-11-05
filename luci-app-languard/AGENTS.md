# AGENTS.md

Working notes for anyone (human or agent) changing this repository. Read this
before touching the code; most of it is knowledge that cost a broken router to
acquire.

## What this is

`luci-app-languard` — an OpenWrt access-control app. Devices, addresses,
login-attack blocking, reverse-proxy awareness, domain blocking, ARP alerts,
application identification and per-app DSCP rules.

## Branches

| Branch | Meaning |
|---|---|
| `main` | stable, stops at v2.4.0 |
| `feature/app-identification` | application tab, per-device stats, DSCP rules, fingerprint sampling, Clash bypass |

`main` was force-pushed back to v2.4.0 on purpose. Do not merge the feature
branch into it without asking.

## The router this runs on

```
OpenWrt 25.12.5 · kernel 6.12.94 · x86_64 · 2 GB RAM · ~250 MB free on /
package manager: apk (not opkg) · nftables 1.1.6 · iproute2 6.18 + libbpf
lucky (reverse proxy) on :1443 · honk (eBPF TPROXY) with domain++ DNS
microsocks on :1080 (authenticated inbound SOCKS5, WAN-forwarded)
qosmate: hfsc on pppoe-wan, 999/80 Mbit
```

State lives in `/etc/languard/*.json`. Deploy by copying files and restarting
`rpcd`; there is no package build in the loop.

## Non-negotiable constraints

1. **Never interrupt the LAN.** No `fw4 reload`, no `dnsmasq restart` and no
   service restart on a scheduled path. A scheduled feed refresh once reloaded
   the whole firewall; that is what this rule exists to prevent.
2. **Never block a trusted proxy.** The address in `trusted_proxies.json` is
   what every reverse-proxied service sits behind.
3. **Derived artifacts must be reconciled, not appended.** Anything computed
   from the rule set (the QoS nft sets, the honk bypass include) has to be
   recomputed from scratch on every apply, so removing a rule removes its
   entries.
4. **A state/kernel mismatch must be fixable from the UI**, not by SSH.

## Environment traps that have already bitten

| Trap | Symptom | Rule |
|---|---|---|
| Lua 5.1 has no bitwise operators | `unexpected symbol near '<'` | use arithmetic (`math.floor(a / size)`) |
| `gmatch("[^;]*")` double-matches consecutive separators | fields shift by one | split with `(s .. ";"):gmatch("([^;]*);")` |
| `""` is truthy in Lua | a device-only rule rendered as `ip daddr 0.0.0.0` | test `x ~= ""` explicitly |
| `find("%.", 1, true)` is a literal `%.` | domain validation always fails | `find(".", 1, true)` |
| rpcd runs with a restrictive umask | files it writes are `600`, dnsmasq silently ignores them | `chmod 644` anything dnsmasq must read |
| Python on Windows writes CRLF | `#!/usr/bin/env lua\r` breaks the rpcd plugin | normalise every file to LF after editing |
| rpcd plugin with CRLF shebang | `ubus list luci.languard` returns nothing and every call is `Not found` — no log line anywhere | `python -c` over the file to strip `\r\n` before scp; check with `head -1 \| hexdump -C` |
| running the plugin with plain `lua` | it hangs forever waiting on stdin, which looks like a code bug | always `< /dev/null`; rpcd itself is fine |
| dnsmasq drops the AD bit | dnscheck.tools reports every DNSSEC row as FAIL even though the upstream resolver validated it (check: query the upstream directly and compare AD) | `/etc/dnsmasq.conf` needs `proxy-dnssec`; the UCI key `proxy_dnssec` is silently ignored, so append the raw option and restart dnsmasq |
| honk exits on NFQUEUE netlink errors | `NFQUEUE listener failed: unexpected netfilter netlink message`; procd's default respawn gives up after 5 tries/hour and the router then has **no DNS and no proxy at all** | `/etc/init.d/honk-watch` polls every 30s and restarts it; do not rely on procd alone |
| `git reset --hard` moves the working tree | the next scp deployed the *old* code over the router | check `git status` before deploying |
| `/etc/nftables.d/*.nft` is included **inside** the fw4 table | a `table` declaration there is a syntax error and the whole firewall fails to reload - every rule silently disappears | only bare chains/sets there; put standalone tables elsewhere |
| Lua 5.1 allows 200 locals per chunk | `main function has more than 200 local variables` - the plugin fails to load and the whole app disappears | hang new state off an existing table (`IDX.*`) instead of adding a local |
| local functions must be declared before use | a call binds to a nil global and the method dies with "No response" | forward-declare at the top of the file |

## How the pieces fit

```
nft table inet fw4
  user_ip_input   prerouting? no - input hook, drops blocked sources
  user_ip_forward forward hook, drops blocked sources/destinations
  openclash       dstnat, redirects TCP to :7892  <- bypass rule is inserted here
  china_ip_route_pass  exists but no rule references it (dead)

nft table inet languard_qos   (prerouting -160, before qosmate)
  sets s_a<id> per app + chain that sets DSCP

nft table inet dscptag        (qosmate, prerouting mangle = -150)
  meta priority set ip dscp map @priomap  -> hfsc class
```

DSCP → class: `ef/cs5 → 1:11`, `cs4/af41 → 1:12`, `cs0 → 1:13`,
`af11/cs2 → 1:14`, `cs1 → 1:15`.

## The hard limit: proxied traffic cannot be shaped per app

honk **terminates** every intercepted TCP connection and opens its own. A DSCP
set on the client's packet therefore never reaches the WAN; the outbound packet
is a new skb generated by honk.

**Consequence:** per-app DSCP works only for traffic that bypasses honk —
game UDP, and anything resolved to a real address. Measured under OpenClash:
930 marked packets on the LAN leg, zero `tos 0x80` on `pppoe-wan`. honk does
not change that physics.

Do not promise per-app shaping for proxied apps. The honest options are a
separate honk outbound per app, or accepting the limit.

## Application identification

honk replaces OpenClash here, and the data source changed with it.

- The native API (`/api/v1/connections`, `127.0.0.1:9527`) gives the real
  client address, domain, outbound group and byte counters. There is no fake
  IP to reverse, so no conntrack join is needed. `dial_mode: domain++` means
  the client's own flow still carries a real address.
- **Proxied flows never reach conntrack.** honk intercepts with eBPF TPROXY,
  so `/proc/net/nf_conntrack` only holds direct traffic. Any accounting built
  on conntrack silently loses every proxied byte.
- **Connections live about ten seconds.** The 55-second tick would miss
  almost all of them, so the watcher runs `honk_poll` every two seconds and
  accumulates deltas in `honk_pending.json`; the tick only classifies and
  commits. Polling is the only way to see short flows.
- **The two APIs do not share connection ids.** Node names only exist in the
  Clash-compatible `/connections` (`chains[1]` is the leaf, `chains[#]` the
  group); the native API's `chain` is empty. Join them on the four-tuple
  `srcIP:srcPort|dstIP:dstPort`, not on `id`.
- Only hostname/address matches count. **Port-only matches are not evidence**:
  `tcp/6000-9000` is Home Assistant, access points and torrent clients, not a
  game. An early version reported 8 MB of Home Assistant traffic as King of
  Glory.
- Payload fingerprints (`00:33|1:66|02:00|03:0a`) are sampled every five
  minutes: tcpdump on the candidate ports only, 96 bytes, ≤250 packets.
  A hit converts a port guess into a learned address.

## The inbound proxy

`microsocks-in` (`/etc/init.d/microsocks-in`) listens on `0.0.0.0:1080` with
`-u languard -P <secret>`, and fw4 forwards WAN `:1080` to it. Outbound traffic
then follows normal honk routing, so the same rules that govern the LAN apply
to the remote client.

The packaged `microsocks` init script must stay disabled: it starts with an
empty username and password, which makes an unauthenticated open proxy on the
same port. Two services cannot share `:1080` — whichever wins decides whether
the proxy is public.

## Verification recipes

```sh
# health
ubus call luci.languard selfcheck

# state vs kernel
ubus call luci.languard iplist '{"limit":"0"}'
nft list set inet fw4 blocked_ip4

# did a rule fire
nft list table inet languard_qos | grep 'ip dscp'

# did a mark survive to the WAN
tcpdump -i pppoe-wan -c 200 -v | grep -oE 'tos 0x[0-9a-f]+' | sort | uniq -c

# feed refresh must not rebuild the ruleset
nft -a list set inet fw4 blocked_ip4 | grep -o 'handle [0-9]*'   # before/after

# is the honk poller alive and seeing flows
ubus call luci.languard honkpoll
wc -c /etc/languard/honk_pending.json    # must grow between two reads

# does the tick classify, and did it fail
cat /etc/languard/tickstate.json         # app_stats false => read "error"
ubus call luci.languard appstats '{"range":""}'

# did a QoS rule reach honk
cat /etc/honk/inc/languard.dae
grep 'routes active' /etc/honk/data/honk.log | tail -1

# inbound SOCKS5 must reject anonymous use
curl -s -m 8 --socks5 127.0.0.1:1080 -o /dev/null -w '%{http_code}\n' https://www.baidu.com   # 000
curl -s -m 8 --socks5 languard:<secret>@127.0.0.1:1080 -o /dev/null -w '%{http_code}\n' https://www.baidu.com  # 200
```

## Style

Terse code, comments explain *why*. No new dependencies without asking.
Delete dead code rather than leaving it behind a flag.
