// SPDX-License-Identifier: GPL-2.0
/*
 * 智能分流数据面，挂在 LAN 口（br-lan）tc：
 *   egress  读取发往设备的明文 DNS 应答，按设备记录 IP → 域名（sr_dns）；出口拒绝 IPv6 时屏蔽命中域名的 AAAA 记录
 *   ingress 新连接首包按“设备 → 分流顺序 → 规则组 → 出口”判断，打 mark 并记入连接表，后续包沿用
 * 转发由 ip rule fwmark + 每个出口一张路由表完成。所有表由用户态（后台服务）填写。
 */
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define NAME_LEN    128   /* 域名（线格式）最长保存字节数 */
#define MAX_LABELS  32
#define MAX_ANSWERS 16
#define MAX_POLICY  32
#define NS          1000000000ULL
#define FNV_OFF     0xcbf29ce484222325ULL
#define FNV_PRIME   0x100000001b3ULL

/* ---------- 域名记录：按设备（MAC）分开，各设备解析到同一 IP 的不同域名互不覆盖 ---------- */
struct dns_key { __u8 mac[6]; __u8 family; __u8 pad; __u8 addr[16]; };
/* name：线格式域名，右对齐（结尾 0 在 name[127]），占 [NAME_LEN - len, NAME_LEN)；st：标签起点位图（按 name 下标） */
struct dns_val { __u8 name[NAME_LEN]; __u32 ttl; __u32 len; __u64 seen_ns; __u64 st[2]; };

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 65536);
	__type(key, struct dns_key);
	__type(value, struct dns_val);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_dns SEC(".maps");

enum { ST_RESP, ST_REC, ST_FAIL, ST_NEW, ST_CONN, ST_AAAA, ST_DNS_STEER, ST_MAX };
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, ST_MAX);
	__type(key, __u32);
	__type(value, __u64);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_stats SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct dns_val);
} scratch SEC(".maps");

/* ---------- 配置与分流 ---------- */
/* idle_s：UDP 连接空闲超时；tcp_idle_s：TCP 连接空闲超时（看到 FIN 后改为 60 秒，看到 RST 立即删除） */
struct cfg { __u32 npol; __u32 mark_mask; __u32 idle_s; __u32 dns_min_s; __u32 tcp_idle_s; __u32 flags; };
#define CF_AAAA 1     /* 有分流需要屏蔽 AAAA */
#define CF_DNS  2     /* 有分流需要按出口转发 DNS */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct cfg);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_cfg SEC(".maps");

#define P_ALL_DEV 1   /* 全部设备 */
#define P_ALL_RG  2   /* 全部目标 */
#define P_NEG     4   /* 规则组取反 */
#define P_NOAAAA  8   /* 出口拒绝 IPv6：命中的设备查询命中域名时屏蔽 AAAA */
#define P_DNS     16  /* 出口配置了 DNS：命中的设备查询命中域名时打出口 mark 交给 nftables DNAT */
struct policy { __u64 dev; __u64 rg; __u32 mark; __u32 flags; };
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, MAX_POLICY);
	__type(key, __u32);
	__type(value, struct policy);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_policy SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, MAX_POLICY);
	__type(key, __u32);
	__type(value, __u64);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_hits SEC(".maps");

/* ---------- 设备 → 设备组位图 ---------- */
struct mac_key { __u8 mac[6]; __u8 pad[2]; };
/* g4/g6：该 MAC 在 IPv4/IPv6 下所属的设备组（IP 规则关联的 MAC 只填 g6）；skip：出口自身，永不分流 */
struct mac_val { __u64 g4; __u64 g6; __u32 skip; __u32 pad; };
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 4096);
	__type(key, struct mac_key);
	__type(value, struct mac_val);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_mac SEC(".maps");

struct lpm4 { __u32 plen; __u8 addr[4]; };
struct lpm6 { __u32 plen; __u8 addr[16]; };
/* LPM 只返回最长前缀：重叠网段的位图由用户态合并好再写入 */
#define LPM(name, ktype, n) struct { \
	__uint(type, BPF_MAP_TYPE_LPM_TRIE); __uint(max_entries, n); \
	__type(key, ktype); __type(value, __u64); \
	__uint(map_flags, BPF_F_NO_PREALLOC); __uint(pinning, LIBBPF_PIN_BY_NAME); } name SEC(".maps")
LPM(sr_dev4, struct lpm4, 4096);     /* 设备源地址 → 设备组 */
LPM(sr_dev6, struct lpm6, 4096);
LPM(sr_skip4, struct lpm4, 1024);    /* 内置保护：私有、组播、本地网段 → 非 0 即跳过 */
LPM(sr_skip6, struct lpm6, 1024);
LPM(sr_rg4, struct lpm4, 262144);    /* 目标地址 → 规则组 */
LPM(sr_rg6, struct lpm6, 262144);

/* 域名后缀哈希 → 规则组。哈希 = FNV-1a 64 逆序作用于线格式后缀的各字节（小写，含结尾 0） */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 262144);
	__type(key, __u64);
	__type(value, __u64);
	__uint(map_flags, BPF_F_NO_PREALLOC);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_dom SEC(".maps");

/* 本地域名后缀哈希（.lan / .local / .arpa / 本机 dhcp domain 等）：命中即不转发 DNS，交由本机 dnsmasq */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 256);
	__type(key, __u64);
	__type(value, __u8);
	__uint(map_flags, BPF_F_NO_PREALLOC);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_dns_skip SEC(".maps");

/* ---------- 最近一次转发的 DNS 查询：设备地址 → 出口 mark。应答截断后设备会改用 TCP 重查，TCP 首包没有域名，跟着这里走 ---------- */
#define DNS_TCP_FOLLOW_S 10
struct recent_key { __u8 family; __u8 pad[3]; __u8 saddr[16]; };
struct recent_val { __u64 seen_ns; __u32 mark; __u32 pad; };
struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 4096);
	__type(key, struct recent_key);
	__type(value, struct recent_val);
} sr_dns_recent SEC(".maps");

/* ---------- 连接表：只记交给出口（mark ≠ 0）的连接 ---------- */
struct conn_key { __u8 family; __u8 proto; __u16 sport; __u16 dport; __u8 pad[2]; __u8 saddr[16]; __u8 daddr[16]; };
struct conn_val { __u64 seen_ns; __u32 mark; __u32 fin; };
struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 65536);
	__type(key, struct conn_key);
	__type(value, struct conn_val);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} sr_conn SEC(".maps");

static __always_inline void bump(__u32 i)
{
	__u64 *v = bpf_map_lookup_elem(&sr_stats, &i);
	if (v) __sync_fetch_and_add(v, 1);
}

/* bpf_loop 回调：第 j 步处理 name[127 - j]，到标签起点时查一次该后缀 */
struct dom_ctx { __u8 name[NAME_LEN]; __u64 st[2]; __u64 h; __u64 g; __u32 start; __u32 chk_skip; __u32 skipped; __u32 pad; };
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct dom_ctx);
} dscratch SEC(".maps");

static long dom_step(__u32 j, void *unused)
{
	__u32 zero = 0;
	struct dom_ctx *d = bpf_map_lookup_elem(&dscratch, &zero);
	if (!d) return 1;
	__u32 i = NAME_LEN - 1 - j;
	if (j >= NAME_LEN || i < d->start) return 1;
	barrier_var(i);
	i &= NAME_LEN - 1;   /* 让校验器确认下标不越界 */
	__u8 b = d->name[i];
	if (b >= 'A' && b <= 'Z') b |= 0x20;   /* 长度字节 ≤ 63，不会被误改 */
	d->h = (d->h ^ b) * FNV_PRIME;
	if ((d->st[i >> 6] >> (i & 63)) & 1) {
		if (d->chk_skip && bpf_map_lookup_elem(&sr_dns_skip, &d->h)) {
			d->skipped = 1;
			return 1;
		}
		__u64 *m = bpf_map_lookup_elem(&sr_dom, &d->h);
		if (m) d->g |= *m;
	}
	return 0;
}

/* 域名的规则组：逆序扫描域名，每到一个标签起点查一次后缀。
 * 独立全局函数：校验器只单独校验一次，否则和外层分支组合后复杂度超限 */
__attribute__((noinline)) __u64 name_groups(struct dns_val *v)
{
	if (!v) return 0;
	__u32 len = v->len, zero = 0;
	if (len < 2 || len > NAME_LEN) return 0;
	struct dom_ctx *d = bpf_map_lookup_elem(&dscratch, &zero);
	if (!d) return 0;
	__builtin_memcpy(d->name, v->name, NAME_LEN);
	d->st[0] = v->st[0]; d->st[1] = v->st[1];
	d->start = NAME_LEN - len; d->h = FNV_OFF; d->g = 0;
	d->chk_skip = 0; d->skipped = 0;
	bpf_loop(NAME_LEN, dom_step, NULL, 0);
	return d->g;
}

/* DNS 查询的域名规则组：遇到本地域名后缀设 *skipped = 1 并提前返回 */
__attribute__((noinline)) __u64 dns_name_groups(struct dns_val *v, __u32 *skipped)
{
	if (!v || !skipped) return 0;
	*skipped = 0;
	__u32 len = v->len, zero = 0;
	if (len < 2 || len > NAME_LEN) return 0;
	struct dom_ctx *d = bpf_map_lookup_elem(&dscratch, &zero);
	if (!d) return 0;
	__builtin_memcpy(d->name, v->name, NAME_LEN);
	d->st[0] = v->st[0]; d->st[1] = v->st[1];
	d->start = NAME_LEN - len; d->h = FNV_OFF; d->g = 0;
	d->chk_skip = 1; d->skipped = 0;
	bpf_loop(NAME_LEN, dom_step, NULL, 0);
	*skipped = d->skipped;
	return d->g;
}

/* 目标 IP 在该设备的域名记录里对应的规则组 */
__attribute__((noinline)) __u64 dom_groups(struct dns_key *dk, __u32 dns_min_s)
{
	if (!dk) return 0;
	struct dns_val *v = bpf_map_lookup_elem(&sr_dns, dk);
	if (!v) return 0;
	__u64 keep = v->ttl > dns_min_s ? v->ttl : dns_min_s;
	if (bpf_ktime_get_ns() - v->seen_ns > keep * NS) return 0;
	return name_groups(v);
}

/* 按分流顺序找第一条命中的；返回该条的 flags | 0x100（命中），未命中返回 0 */
static __always_inline __u32 match_policy(struct cfg *c, __u64 dev, __u64 rg, __u32 *idx)
{
	for (__u32 i = 0; i < MAX_POLICY; i++) {
		if (i >= c->npol) break;
		__u32 key = i;   /* 不能对循环变量取地址：会落到栈上变成未知值，校验器判为死循环 */
		struct policy *p = bpf_map_lookup_elem(&sr_policy, &key);
		if (!p) break;
		if (!(p->flags & P_ALL_DEV) && !(dev & p->dev)) continue;
		int m = (p->flags & P_ALL_RG) || (rg & p->rg);
		if (p->flags & P_NEG) m = !m;
		if (!m) continue;
		*idx = i;
		return p->flags | 0x100;
	}
	return 0;
}

/* AAAA 应答是否要屏蔽：设备 × 域名命中的第一条分流的出口拒绝 IPv6。
 * 只看域名（AAAA 应答还没有被连接，IP 规则组不参与判断） */
__attribute__((noinline)) int aaaa_blocked(struct dns_val *v, struct dns_key *dk)
{
	__u32 zero = 0, idx;
	if (!v || !dk) return 0;
	struct cfg *c = bpf_map_lookup_elem(&sr_cfg, &zero);
	if (!c || !(c->flags & CF_AAAA)) return 0;
	struct mac_key mk = {};
	__builtin_memcpy(mk.mac, dk->mac, 6);
	struct mac_val *mv = bpf_map_lookup_elem(&sr_mac, &mk);
	if (mv && mv->skip) return 0;
	__u64 dev = mv ? mv->g6 : 0, *g;
	if (dk->family == 4) {
		struct lpm4 a = { .plen = 32 };
		__builtin_memcpy(a.addr, dk->addr, 4);
		if ((g = bpf_map_lookup_elem(&sr_dev4, &a))) dev |= *g;
	} else {
		struct lpm6 a = { .plen = 128 };
		__builtin_memcpy(a.addr, dk->addr, 16);
		if ((g = bpf_map_lookup_elem(&sr_dev6, &a))) dev |= *g;
	}
	__u32 f = match_policy(c, dev, name_groups(v), &idx);
	return (f & 0x100) && (f & P_NOAAAA);
}

/* ======================= egress：DNS 应答 ======================= */

/* 跳过一个（可能被压缩的）域名，返回新偏移；失败返回 0。用 bpf_loop 避免外层循环展开，且不用带 ctx 的全局函数（不依赖内核 BTF） */
struct skip_ctx { struct __sk_buff *skb; __u32 pos; __u32 end; };

static long skip_step(__u32 i, void *arg)
{
	struct skip_ctx *c = arg;
	__u8 l;
	if (bpf_skb_load_bytes(c->skb, c->pos, &l, 1)) return 1;
	if ((l & 0xC0) == 0xC0) { c->end = c->pos + 2; return 1; }
	if (l == 0) { c->end = c->pos + 1; return 1; }
	if (l > 63) return 1;
	c->pos += l + 1;
	return 0;
}

static __always_inline __u32 skip_name(struct __sk_buff *skb, __u32 pos)
{
	struct skip_ctx c = { .skb = skb, .pos = pos, .end = 0 };
	bpf_loop(MAX_LABELS, skip_step, &c, 0);
	return c.end;
}

SEC("tc/egress")
int sr_egress(struct __sk_buff *skb)
{
	__u16 proto = bpf_ntohs(skb->protocol);
	__u32 l4, zero = 0;
	__u8 b;

	if (proto == 0x0800) {
		__u8 vihl, ipproto;
		if (bpf_skb_load_bytes(skb, 14, &vihl, 1) || bpf_skb_load_bytes(skb, 14 + 9, &ipproto, 1)) return TC_ACT_OK;
		if (ipproto != 17) return TC_ACT_OK;
		l4 = 14 + (vihl & 0x0F) * 4;
	} else if (proto == 0x86DD) {
		__u8 nh;
		if (bpf_skb_load_bytes(skb, 14 + 6, &nh, 1) || nh != 17) return TC_ACT_OK;
		l4 = 14 + 40;
	} else {
		return TC_ACT_OK;
	}

	__u16 sport;
	if (bpf_skb_load_bytes(skb, l4, &sport, 2) || bpf_ntohs(sport) != 53) return TC_ACT_OK;
	/* 设备 = 应答的目标 MAC；dev 另存设备的 IP（发往的地址），用于查 IP 规则 */
	struct dns_key dev = { .family = proto == 0x0800 ? 4 : 6 };
	if (bpf_skb_load_bytes(skb, 0, dev.mac, 6)) return TC_ACT_OK;
	if (dev.family == 4 ? bpf_skb_load_bytes(skb, 14 + 16, dev.addr, 4) : bpf_skb_load_bytes(skb, 14 + 24, dev.addr, 16)) return TC_ACT_OK;

	__u32 dns = l4 + 8;
	__u16 hdr[6];
	if (bpf_skb_load_bytes(skb, dns, hdr, sizeof(hdr))) return TC_ACT_OK;
	__u16 flags = bpf_ntohs(hdr[1]), qd = bpf_ntohs(hdr[2]), an = bpf_ntohs(hdr[3]);
	if (!(flags & 0x8000) || (flags & 0x000F) || qd != 1 || an == 0) return TC_ACT_OK;
	bump(ST_RESP);

	struct dns_val *v = bpf_map_lookup_elem(&scratch, &zero);
	if (!v) return TC_ACT_OK;

	__u32 qstart = dns + 12, pos = qstart;
	for (int i = 0; i < MAX_LABELS; i++) {
		if (bpf_skb_load_bytes(skb, pos, &b, 1)) goto fail;
		if (b == 0) break;
		if (b > 63) goto fail;
		pos += b + 1;
	}
	if (bpf_skb_load_bytes(skb, pos, &b, 1) || b != 0) goto fail;
	__u32 qlen = pos - qstart + 1;
	if (qlen > NAME_LEN) goto fail;
	/* 逐字节右对齐复制，同时记下标签起点；barrier_var 防止编译器删掉循环上限和下标掩码 */
	barrier_var(qlen);
	__u32 next = 0;
	v->st[0] = v->st[1] = 0;
	for (int i = 0; i < NAME_LEN; i++) {
		if (i >= qlen) break;
		if (bpf_skb_load_bytes(skb, qstart + i, &b, 1)) goto fail;
		__u32 idx = NAME_LEN - qlen + i;
		barrier_var(idx);
		idx &= NAME_LEN - 1;
		v->name[idx] = b;
		if (i == next && i + 1 < qlen) {
			v->st[idx >> 6] |= 1ULL << (idx & 63);
			next += b + 1;
		}
	}
	v->len = qlen;
	__u16 qtype;
	if (bpf_skb_load_bytes(skb, pos + 1, &qtype, 2)) goto fail;
	int block = bpf_ntohs(qtype) == 28 && aaaa_blocked(v, &dev);
	pos += 1 + 4;

	for (int i = 0; i < MAX_ANSWERS; i++) {
		if (i >= an) break;
		pos = skip_name(skb, pos);
		if (!pos) goto fail;
		__u8 rr[10];
		if (bpf_skb_load_bytes(skb, pos, rr, sizeof(rr))) goto fail;
		__u16 type = (rr[0] << 8) | rr[1], rdlen = (rr[8] << 8) | rr[9];
		__u32 ttl = ((__u32)rr[4] << 24) | ((__u32)rr[5] << 16) | ((__u32)rr[6] << 8) | rr[7];
		if (block && type == 28) {
			/* 屏蔽：改成私用类型 65280，长度不变只需增量更新校验和；设备会忽略没问过的类型 */
			__u16 from = bpf_htons(28), to = bpf_htons(65280);
			bpf_l4_csum_replace(skb, l4 + 6, from, to, sizeof(__u16) | (dev.family == 4 ? BPF_F_MARK_MANGLED_0 : 0));
			bpf_skb_store_bytes(skb, pos, &to, sizeof(to), 0);
			bump(ST_AAAA);
			pos += 10 + rdlen;
			continue;
		}
		pos += 10;
		struct dns_key k = {};
		__builtin_memcpy(k.mac, dev.mac, 6);
		if (type == 1 && rdlen == 4) {
			k.family = 4;
			if (bpf_skb_load_bytes(skb, pos, k.addr, 4)) goto fail;
		} else if (type == 28 && rdlen == 16) {
			k.family = 6;
			if (bpf_skb_load_bytes(skb, pos, k.addr, 16)) goto fail;
		}
		if (k.family) {
			v->ttl = ttl;
			v->seen_ns = bpf_ktime_get_ns();
			bpf_map_update_elem(&sr_dns, &k, v, BPF_ANY);
			bump(ST_REC);
		}
		pos += rdlen;
	}
	return TC_ACT_OK;
fail:
	bump(ST_FAIL);
	return TC_ACT_OK;
}

/* ======================= ingress：首包判断 ======================= */

static __always_inline int is_local(struct __sk_buff *skb, struct conn_key *k)
{
	struct bpf_fib_lookup f = {};
	f.ifindex = skb->ingress_ifindex;
	if (k->family == 4) {
		f.family = 2;   /* AF_INET */
		__builtin_memcpy(&f.ipv4_src, k->saddr, 4);
		__builtin_memcpy(&f.ipv4_dst, k->daddr, 4);
	} else {
		f.family = 10;  /* AF_INET6 */
		__builtin_memcpy(f.ipv6_src, k->saddr, 16);
		__builtin_memcpy(f.ipv6_dst, k->daddr, 16);
	}
	return bpf_fib_lookup(skb, &f, sizeof(f), 0) == BPF_FIB_LKUP_RET_NOT_FWDED;
}

/* 明文 DNS 查询（UDP 53）：解析请求域名，按“设备 × 域名”命中带 P_DNS 的策略时打出口 mark 交给 nftables DNAT */
struct qlen_ctx { struct __sk_buff *skb; __u32 pos; __u32 labels; __u8 done; __u8 bad; __u16 pad; };

static long qlen_step(__u32 i, void *arg)
{
	struct qlen_ctx *q = arg;
	__u8 b;
	if (bpf_skb_load_bytes(q->skb, q->pos, &b, 1)) { q->bad = 1; return 1; }
	if (b == 0) { q->done = 1; return 1; }
	if (b > 63) { q->bad = 1; return 1; }
	q->labels++;
	q->pos += b + 1;
	return 0;
}

struct qcopy_ctx { struct __sk_buff *skb; struct dns_val *v; __u32 qstart; __u32 qlen; __u32 next; __u8 bad; };

static long qcopy_step(__u32 i, void *arg)
{
	struct qcopy_ctx *q = arg;
	if (i >= q->qlen || i >= NAME_LEN) return 1;
	__u8 b;
	if (bpf_skb_load_bytes(q->skb, q->qstart + i, &b, 1)) { q->bad = 1; return 1; }
	__u32 idx = NAME_LEN - q->qlen + i;
	barrier_var(idx);
	idx &= NAME_LEN - 1;
	q->v->name[idx] = b;
	if (i == q->next && i + 1 < q->qlen) {
		q->v->st[idx >> 6] |= 1ULL << (idx & 63);
		q->next += b + 1;
	}
	return 0;
}

static __always_inline int steer_dns_query(struct __sk_buff *skb, struct cfg *c, struct conn_key *k, __u32 l4)
{
	__u32 dns = l4 + 8, zero = 0;
	__u16 hdr[6];
	if (bpf_skb_load_bytes(skb, dns, hdr, sizeof(hdr))) return 0;
	__u16 flags = bpf_ntohs(hdr[1]), qd = bpf_ntohs(hdr[2]);
	/* 只处理标准明文查询：QR=0、Opcode=0、QDCOUNT=1 */
	if ((flags & 0xF800) || qd != 1) return 0;

	struct mac_key mk = {};
	if (bpf_skb_load_bytes(skb, 6, mk.mac, 6)) return 0;
	struct mac_val *mv = bpf_map_lookup_elem(&sr_mac, &mk);
	if (mv && mv->skip) return 0;

	__u32 qstart = dns + 12;
	struct qlen_ctx lc = { .skb = skb, .pos = qstart };
	bpf_loop(MAX_LABELS, qlen_step, &lc, 0);
	if (lc.bad || !lc.done || lc.labels < 2) return 0;   /* 单标签主机名（如 nas / openwrt）始终交本机 dnsmasq */
	__u32 qlen = lc.pos - qstart + 1;
	if (qlen < 2 || qlen > NAME_LEN) return 0;

	struct dns_val *v = bpf_map_lookup_elem(&scratch, &zero);
	if (!v) return 0;
	v->st[0] = v->st[1] = 0;
	v->len = qlen;
	struct qcopy_ctx cc = { .skb = skb, .v = v, .qstart = qstart, .qlen = qlen, .next = 0 };
	bpf_loop(NAME_LEN, qcopy_step, &cc, 0);
	if (cc.bad) return 0;

	__u32 skipped = 0;
	__u64 rg = dns_name_groups(v, &skipped);
	if (skipped) return 0;

	__u64 dev = 0, *g;
	if (k->family == 4) {
		struct lpm4 s4 = { .plen = 32 };
		__builtin_memcpy(s4.addr, k->saddr, 4);
		if ((g = bpf_map_lookup_elem(&sr_dev4, &s4))) dev |= *g;
		if (mv) dev |= mv->g4;
	} else {
		struct lpm6 s6 = { .plen = 128 };
		__builtin_memcpy(s6.addr, k->saddr, 16);
		if ((g = bpf_map_lookup_elem(&sr_dev6, &s6))) dev |= *g;
		if (mv) dev |= mv->g6;
	}

	__u32 idx = 0;
	__u32 f = match_policy(c, dev, rg, &idx);
	if (!(f & 0x100) || !(f & P_DNS)) return 0;
	struct policy *p = bpf_map_lookup_elem(&sr_policy, &idx);
	if (!p || !p->mark) return 0;
	skb->mark = (skb->mark & ~c->mark_mask) | p->mark;
	struct recent_key rk = { .family = k->family };
	__builtin_memcpy(rk.saddr, k->saddr, 16);
	struct recent_val rv = { .seen_ns = bpf_ktime_get_ns(), .mark = p->mark };
	bpf_map_update_elem(&sr_dns_recent, &rk, &rv, BPF_ANY);
	bump(ST_DNS_STEER);
	return 1;
}

/* TCP 53 的 SYN：同一设备几秒内刚有 UDP 查询转给了某个出口，这条 TCP 连接也交给它，并记入连接表让后续包沿用 */
static __always_inline int steer_dns_tcp(struct cfg *c, struct conn_key *k, struct __sk_buff *skb)
{
	struct recent_key rk = { .family = k->family };
	__builtin_memcpy(rk.saddr, k->saddr, 16);
	struct recent_val *rv = bpf_map_lookup_elem(&sr_dns_recent, &rk);
	__u64 now = bpf_ktime_get_ns();
	if (!rv || now - rv->seen_ns > DNS_TCP_FOLLOW_S * NS) return 0;
	skb->mark = (skb->mark & ~c->mark_mask) | rv->mark;
	struct conn_val nv = { .seen_ns = now, .mark = rv->mark };
	bpf_map_update_elem(&sr_conn, k, &nv, BPF_ANY);
	bump(ST_DNS_STEER);
	return 1;
}

SEC("tc/ingress")
int sr_ingress(struct __sk_buff *skb)
{
	__u32 zero = 0;
	struct cfg *c = bpf_map_lookup_elem(&sr_cfg, &zero);
	if (!c) return TC_ACT_OK;

	struct conn_key k = {};
	__u16 proto = bpf_ntohs(skb->protocol);
	__u32 l4;
	if (proto == 0x0800) {
		__u8 h[20];
		if (bpf_skb_load_bytes(skb, 14, h, sizeof(h))) return TC_ACT_OK;
		/* shortcut: 非首个分片没有端口，按直连处理；遇到经出口的大 UDP 分片再改 */
		if ((h[6] & 0x1F) | h[7]) return TC_ACT_OK;
		k.family = 4; k.proto = h[9];
		__builtin_memcpy(k.saddr, h + 12, 4);
		__builtin_memcpy(k.daddr, h + 16, 4);
		l4 = 14 + (h[0] & 0x0F) * 4;
	} else if (proto == 0x86DD) {
		__u8 h[40];
		if (bpf_skb_load_bytes(skb, 14, h, sizeof(h))) return TC_ACT_OK;
		/* shortcut: 不解析扩展头，带扩展头的包按无端口处理、不记连接 */
		k.family = 6; k.proto = h[6];
		__builtin_memcpy(k.saddr, h + 8, 16);
		__builtin_memcpy(k.daddr, h + 24, 16);
		l4 = 14 + 40;
	} else {
		return TC_ACT_OK;
	}

	__u8 tcpf = 0;
	int stateful = k.proto == 6 || k.proto == 17;
	if (stateful) {
		__u16 p[2];
		if (bpf_skb_load_bytes(skb, l4, p, sizeof(p))) return TC_ACT_OK;
		k.sport = p[0]; k.dport = p[1];
		if (k.proto == 6 && bpf_skb_load_bytes(skb, l4 + 13, &tcpf, 1)) return TC_ACT_OK;
	}

	/* 明文 DNS 查询：在连接表与本地/私有保护之前处理，按“设备 × 域名”打出口 mark 交给 nftables DNAT */
	if (k.proto == 17 && bpf_ntohs(k.dport) == 53 && (c->flags & CF_DNS) && c->npol) {
		if (steer_dns_query(skb, c, &k, l4)) return TC_ACT_OK;
	}
	if (k.proto == 6 && (tcpf & 0x12) == 0x02 && bpf_ntohs(k.dport) == 53 && (c->flags & CF_DNS) && c->npol) {
		if (steer_dns_tcp(c, &k, skb)) return TC_ACT_OK;
	}

	__u64 now = bpf_ktime_get_ns();
	if (stateful) {
		struct conn_val *cv = bpf_map_lookup_elem(&sr_conn, &k);
		__u64 to = k.proto == 17 ? c->idle_s : cv && cv->fin ? 60 : c->tcp_idle_s;
		if (cv && now - cv->seen_ns < to * NS) {
			cv->seen_ns = now;
			skb->mark = (skb->mark & ~c->mark_mask) | cv->mark;
			/* TCP：设备发出 RST 即删除；发出 FIN 后再保留 60 秒，让最后的 ACK 仍走原出口 */
			if (k.proto == 6 && (tcpf & 0x04)) bpf_map_delete_elem(&sr_conn, &k);
			else if (k.proto == 6 && (tcpf & 0x01)) cv->fin = 1;
			return TC_ACT_OK;
		}
		/* TCP 只在 SYN 上判断：不在表里的已有连接（插件启动前建立、或判为直连）保持直连 */
		if (k.proto == 6 && (tcpf & 0x12) != 0x02) return TC_ACT_OK;
	}
	if (!c->npol) return TC_ACT_OK;   /* 没有分流：已有连接仍沿用出口，新连接直连 */

	/* 内置保护：出口自身、私有/组播/本地网段、发往路由器本机 */
	struct mac_key mk = {};
	if (bpf_skb_load_bytes(skb, 6, mk.mac, 6)) return TC_ACT_OK;
	struct mac_val *mv = bpf_map_lookup_elem(&sr_mac, &mk);
	if (mv && mv->skip) return TC_ACT_OK;

	__u64 dev = 0, rg = 0, *g;
	struct lpm4 s4 = { .plen = 32 }, d4 = { .plen = 32 };
	struct lpm6 s6 = { .plen = 128 }, d6 = { .plen = 128 };
	if (k.family == 4) {
		__builtin_memcpy(d4.addr, k.daddr, 4);
		if (bpf_map_lookup_elem(&sr_skip4, &d4)) return TC_ACT_OK;
		__builtin_memcpy(s4.addr, k.saddr, 4);
		if ((g = bpf_map_lookup_elem(&sr_dev4, &s4))) dev |= *g;
		if ((g = bpf_map_lookup_elem(&sr_rg4, &d4))) rg |= *g;
		if (mv) dev |= mv->g4;
	} else {
		__builtin_memcpy(d6.addr, k.daddr, 16);
		if (bpf_map_lookup_elem(&sr_skip6, &d6)) return TC_ACT_OK;
		__builtin_memcpy(s6.addr, k.saddr, 16);
		if ((g = bpf_map_lookup_elem(&sr_dev6, &s6))) dev |= *g;
		if ((g = bpf_map_lookup_elem(&sr_rg6, &d6))) rg |= *g;
		if (mv) dev |= mv->g6;
	}
	if (is_local(skb, &k)) return TC_ACT_OK;
	struct dns_key dk = { .family = k.family };
	__builtin_memcpy(dk.mac, mk.mac, 6);
	__builtin_memcpy(dk.addr, k.daddr, 16);
	rg |= dom_groups(&dk, c->dns_min_s);
	bump(ST_NEW);

	__u32 idx = 0;
	if (!(match_policy(c, dev, rg, &idx) & 0x100)) return TC_ACT_OK;
	__u64 *hit = bpf_map_lookup_elem(&sr_hits, &idx);
	if (hit) *hit += 1;
	struct policy *p = bpf_map_lookup_elem(&sr_policy, &idx);
	if (!p || !p->mark) return TC_ACT_OK;   /* 直连：命中即停止，不记连接 */
	skb->mark = (skb->mark & ~c->mark_mask) | p->mark;
	if (stateful) {
		struct conn_val nv = { .seen_ns = now, .mark = p->mark };
		bpf_map_update_elem(&sr_conn, &k, &nv, BPF_ANY);
		bump(ST_CONN);
	}
	return TC_ACT_OK;
}

char LICENSE[] SEC("license") = "GPL";
