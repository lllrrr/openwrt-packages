//! rtnetlink 客户端（手写编解码，不引入第三方 netlink 库）。
//!
//! 为什么手写：任务书要求「优先使用 netlink/系统 API 而非 fork 进程」。`ip rule`/`ip route`
//! 的解析既慢又依赖 busybox/iproute2 的具体输出格式，而策略路由的读改是本插件的高频路径。
//! 现有 Rust crate（`rtnetlink`/`netlink-packet-*`）依赖 tokio-netlink 的私有订阅语义、
//! 版本迭代快、且对 `FRA_FWMASK`/`RTA_TABLE` 这类我们最关心的字段并不比 200 行手写更可靠，
//! 因此这里直接按 UAPI 结构编解码。
//!
//! 所有常量取自内核 UAPI 头（`linux/rtnetlink.h`、`linux/fib_rules.h`、`linux/netlink.h`），
//! 已在构建环境用 gcc 对 `sizeof(struct rtmsg)=12`、`sizeof(struct fib_rule_hdr)=12`、
//! `sizeof(struct nlmsghdr)=16` 做过校验。**netlink 的整数属性是主机字节序**，
//! 而 IP 地址属性是原始网络序字节，因此本模块只支持小端目标（大端在 [`Connection::open`] 明确报错）。

use std::net::IpAddr;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::Mutex;
use std::time::Duration;

use crate::logging;
use crate::{Error, Result};

// ---- linux/netlink.h ----
const NLMSG_HDRLEN: usize = 16;
const NLMSG_NOOP: u16 = 1;
const NLMSG_ERROR: u16 = 2;
const NLMSG_DONE: u16 = 3;
const NLMSG_OVERRUN: u16 = 4;
const NLM_F_REQUEST: u16 = 0x0001;
const NLM_F_ACK: u16 = 0x0004;
/// 注意：`NLM_F_ROOT == NLM_F_REPLACE == 0x100`、`NLM_F_MATCH == NLM_F_EXCL == 0x200`，
/// 这是内核 UAPI 里有意的复用，DUMP = ROOT|MATCH。
const NLM_F_DUMP: u16 = 0x0100 | 0x0200;
const NLM_F_CREATE: u16 = 0x0400;
const NLM_F_EXCL: u16 = 0x0200;
const NETLINK_ROUTE: i32 = 0;

// ---- linux/rtnetlink.h ----
const RTM_NEWROUTE: u16 = 24;
const RTM_DELROUTE: u16 = 25;
const RTM_GETROUTE: u16 = 26;
const RTM_NEWADDR: u16 = 20;
const RTM_GETADDR: u16 = 22;
const RTM_NEWRULE: u16 = 32;
const RTM_DELRULE: u16 = 33;
const RTM_GETRULE: u16 = 34;

// ---- linux/if_addr.h（IFA_* 与 struct ifaddrmsg，已用 gcc 校验 sizeof=8）----
pub const IFA_ADDRESS: u16 = 1;
pub const IFA_LOCAL: u16 = 2;
pub const IFA_LABEL: u16 = 3;
pub const IFA_FLAGS: u16 = 8;
/// `IFA_F_SECONDARY`（IPv6 场景下内核用同一个位表示 `IFA_F_TEMPORARY`
/// 隐私扩展临时地址）——本层通过 [`AddrEntry::secondary`] 暴露给源地址选择。
const IFA_F_SECONDARY: u32 = 0x01;
const IFA_F_DEPRECATED: u32 = 0x20;
const IFA_F_PERMANENT: u32 = 0x80;
const IFA_F_TENTATIVE: u32 = 0x40;

pub const RTPROT_UNSPEC: u8 = 0;
pub const RTA_UNSPEC: u16 = 0;
pub const RTA_DST: u16 = 1;
pub const RTA_OIF: u16 = 4;
pub const RTA_GATEWAY: u16 = 5;
pub const RTA_PRIORITY: u16 = 6;
pub const RTA_PREFSRC: u16 = 7;
pub const RTA_TABLE: u16 = 15;

pub const RT_TABLE_UNSPEC: u8 = 0;
pub const RT_TABLE_MAIN: u8 = 254;
pub const RT_TABLE_LOCAL: u8 = 255;
pub const RT_SCOPE_UNIVERSE: u8 = 0;
pub const RT_SCOPE_LINK: u8 = 253;
pub const RT_SCOPE_HOST: u8 = 254;

pub const RTPROT_KERNEL: u8 = 2;
pub const RTPROT_BOOT: u8 = 3;
pub const RTPROT_STATIC: u8 = 4;
pub const RTPROT_RA: u8 = 9;
pub const RTPROT_DHCP: u8 = 16;

pub const RTN_UNSPEC: u8 = 0;
pub const RTN_UNICAST: u8 = 1;
pub const RTN_LOCAL: u8 = 2;
pub const RTN_BROADCAST: u8 = 3;
pub const RTN_ANYCAST: u8 = 4;
pub const RTN_MULTICAST: u8 = 5;
pub const RTN_BLACKHOLE: u8 = 6;
pub const RTN_UNREACHABLE: u8 = 7;
pub const RTN_PROHIBIT: u8 = 8;
pub const RTN_THROW: u8 = 9;

/// 本插件安装的规则/路由的来源标记。内核允许任意 `RTPROT_*`，
/// 我们用 `RTPROT_STATIC`（与人工 `ip rule add` 一致），所有权判定不依赖它，
/// 而依赖优先级区间 + 表号 + 魔数三重条件（见 [`crate::system::route`]）。
pub const OUR_RTPROT: u8 = RTPROT_STATIC;

// ---- linux/fib_rules.h ----
pub const FRA_DST: u16 = 1;
pub const FRA_SRC: u16 = 2;
pub const FRA_IIFNAME: u16 = 3;
pub const FRA_PRIORITY: u16 = 6;
pub const FRA_FWMARK: u16 = 10;
pub const FRA_TABLE: u16 = 15;
pub const FRA_FWMASK: u16 = 16;
pub const FRA_PROTOCOL: u16 = 21;
pub const FR_ACT_TO_TBL: u8 = 1;
pub const FR_ACT_GOTO: u8 = 2;
pub const FR_ACT_NOP: u8 = 3;
pub const FR_ACT_BLACKHOLE: u8 = 6;
pub const FR_ACT_UNREACHABLE: u8 = 7;
pub const FR_ACT_PROHIBIT: u8 = 8;

const AF_INET: u8 = 2;
const AF_INET6: u8 = 10;

/// 地址族。策略路由的 v4/v6 必须分开处理（内核是两套规则与两套表）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    V4,
    V6,
}

impl Family {
    pub fn af(self) -> u8 {
        match self {
            Family::V4 => AF_INET,
            Family::V6 => AF_INET6,
        }
    }

    pub fn from_af(af: u8) -> Option<Family> {
        match af {
            AF_INET => Some(Family::V4),
            AF_INET6 => Some(Family::V6),
            _ => None,
        }
    }

    pub fn addr_len(self) -> usize {
        match self {
            Family::V4 => 4,
            Family::V6 => 16,
        }
    }

    /// 由地址推导地址族。不用 std 的 `is_v4`（不同版本改名不一致），
    /// 模式匹配对 MSRV 最友好，也保证本模块只有一个判定入口。
    pub const fn of(addr: IpAddr) -> Family {
        match addr {
            IpAddr::V4(_) => Family::V4,
            IpAddr::V6(_) => Family::V6,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Family::V4 => "ipv4",
            Family::V6 => "ipv6",
        }
    }
}

/// 一条已存在的策略规则（`ip rule show` 的内核视角）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleEntry {
    pub family: Family,
    pub priority: u32,
    pub table: u32,
    pub action: u8,
    /// `fwmark` 匹配值；未使用 fwmark 的规则为 None。
    pub fwmark: Option<u32>,
    /// `fwmask`；内核在只给 mark 时掩码默认为全 1。
    pub fwmask: Option<u32>,
    pub iifname: Option<String>,
    pub src: Option<(IpAddr, u8)>,
    pub dst: Option<(IpAddr, u8)>,
    pub protocol: Option<u8>,
    pub flags: u32,
}

impl RuleEntry {
    /// 本插件是否拥有这条规则：优先级在保留区间、掩码是槽位掩码、
    /// mark 是个合法槽位、且选中的表号与该槽位的约定表号一致。
    ///
    /// 四个条件同时成立才敢删，少一个都只报告冲突 —— 误删别人的规则
    /// 比留下我们的垃圾严重得多。
    pub fn is_ours(&self) -> bool {
        use crate::marks;
        let Some(mark) = self.fwmark else {
            return false;
        };
        let Some(mask) = self.fwmask else {
            return false;
        };
        if mask != marks::RULE_MASK {
            return false;
        }
        let slot = marks::slot_of(mark);
        if slot == 0 || slot > marks::MAX_WANS {
            return false;
        }
        if self.table != marks::table_of(slot) {
            return false;
        }
        crate::system::route::is_our_priority(self.priority)
    }
}

/// 一条已存在的路由。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RouteEntry {
    pub family: Family,
    pub table: u32,
    pub dst_len: u8,
    pub dst: Option<IpAddr>,
    pub gateway: Option<IpAddr>,
    pub oif: Option<u32>,
    pub prefsrc: Option<IpAddr>,
    pub priority: u32,
    pub protocol: u8,
    pub scope: u8,
    pub kind: u8,
}

impl RouteEntry {
    /// 目标前缀文本，用于日志与 RPC（默认路由显示为 `default`）。
    pub fn prefix_text(&self) -> String {
        match (&self.dst, self.dst_len, self.family) {
            (None, 0, Family::V4) => "default".into(),
            (None, 0, Family::V6) => "default".into(),
            (Some(ip), n, _) => format!("{ip}/{n}"),
            (None, n, _) => format!("(no-dst)/{n}"),
        }
    }

    pub fn is_default(&self) -> bool {
        self.dst_len == 0 && self.dst.is_none()
    }

    /// 是否属于本插件拥有的表（表号由槽位决定）。
    pub fn in_our_table(&self) -> bool {
        let t = self.table;
        t > crate::marks::TABLE_BASE
            && t <= crate::marks::TABLE_BASE + crate::marks::MAX_WANS as u32
    }
}

/// 一条接口地址（`ip addr show` 的内核视角）。
///
/// 用途：为策略路由挑 `prefsrc`、判断 5G 模块重拨后地址是否变了、
/// 以及给 UI 显示真实地址（而不是猜）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddrEntry {
    pub family: Family,
    pub prefix_len: u8,
    pub ifindex: u32,
    /// 点对点链路上 `IFA_ADDRESS` 是对端地址，本机地址在 `IFA_LOCAL`；
    /// 这里统一把「本机地址」放在 address 字段（有 IFA_LOCAL 时优先取它）。
    pub address: IpAddr,
    pub label: Option<String>,
    pub permanent: bool,
    pub deprecated: bool,
    pub tentative: bool,
    /// `IFA_F_SECONDARY`：IPv6 临时地址 / IPv4 secondary 地址。
    /// 这类地址会轮换失效，不能当作长期稳定的 prefsrc。
    pub secondary: bool,
}

/// 要安装/删除的规则。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleSpec {
    pub family: Family,
    pub priority: u32,
    pub table: u32,
    /// 槽位标记值（低 8 位）。
    pub fwmark: u32,
    pub fwmask: u32,
}

/// 要安装/删除的路由。`dst_len == 0 && dst == None` 表示默认路由。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RouteSpec {
    pub family: Family,
    pub table: u32,
    pub dst: Option<IpAddr>,
    pub dst_len: u8,
    pub gateway: Option<IpAddr>,
    pub oif: Option<u32>,
    pub prefsrc: Option<IpAddr>,
    pub kind: u8,
    pub scope: u8,
    pub priority: u32,
}

impl RouteSpec {
    /// 经网关的默认路由。**scope 必须是 UNIVERSE（global）**：带网关的路由
    /// 由 FIB 解析下一跳，iproute2 对 `via GW` 一律用 global scope。
    /// 曾经写成 RT_SCOPE_LINK，内核直接 ENETUNREACH 拒绝安装 ——
    /// 真机集成测试（WSL + 真 nft/netlink）抓出来的，替身不验证所以单测全绿。
    pub fn default_v4(table: u32, gw: IpAddr, oif: u32, prefsrc: Option<IpAddr>) -> RouteSpec {
        RouteSpec {
            family: Family::V4,
            table,
            dst: None,
            dst_len: 0,
            gateway: Some(gw),
            oif: Some(oif),
            prefsrc,
            kind: RTN_UNICAST,
            scope: RT_SCOPE_UNIVERSE,
            priority: 1024,
        }
    }

    /// 点对点/蜂窝链路的默认路由：`default dev wwan0 scope link`，没有网关。
    /// netifd 在 PDP 上下文里就是这样装的，我们必须保持一致。
    pub fn default_dev(table: u32, oif: u32, prefsrc: Option<IpAddr>) -> RouteSpec {
        RouteSpec {
            family: Family::V4,
            table,
            dst: None,
            dst_len: 0,
            gateway: None,
            oif: Some(oif),
            prefsrc,
            kind: RTN_UNICAST,
            scope: RT_SCOPE_LINK,
            priority: 1024,
        }
    }

    pub fn local_host(table: u32, addr: IpAddr, oif: u32) -> RouteSpec {
        let len = if matches!(addr, IpAddr::V4(_)) {
            32
        } else {
            128
        };
        RouteSpec {
            family: Family::of(addr),
            table,
            dst: Some(addr),
            dst_len: len,
            gateway: None,
            oif: Some(oif),
            prefsrc: None,
            kind: RTN_LOCAL,
            scope: RT_SCOPE_HOST,
            priority: 0,
        }
    }
}

/// 与内核对话的能力接口。生产用 [`Connection`]，测试用 [`FakeNetlink`]，
/// 这样路由/规则收敛逻辑可以在无 root、无 netlink 的环境下做单元测试。
pub trait RouteOps: Send + Sync {
    fn dump_rules(&self, family: Family) -> Result<Vec<RuleEntry>>;
    fn dump_routes(&self, family: Family, table: u32) -> Result<Vec<RouteEntry>>;
    /// 接口地址：挑 prefsrc、判断重拨后地址变化、UI 显示真实地址。
    fn dump_addresses(&self, family: Family) -> Result<Vec<AddrEntry>>;
    fn add_rule(&self, spec: &RuleSpec) -> Result<()>;
    fn del_rule(&self, spec: &RuleSpec) -> Result<()>;
    fn add_route(&self, spec: &RouteSpec) -> Result<()>;
    fn del_route(&self, spec: &RouteSpec) -> Result<()>;
}

// ================= 编码器（纯函数） =================

#[derive(Default)]
pub struct Buf(Vec<u8>);

impl Buf {
    pub fn new() -> Buf {
        Buf(Vec::new())
    }

    pub fn u8(&mut self, v: u8) {
        self.0.push(v);
    }

    pub fn u16(&mut self, v: u16) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }

    pub fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }

    /// 属性：4 字节头（长度+类型，均为 u16）+ 负载 + 0 填充到 4 字节边界。
    pub fn attr(&mut self, ty: u16, payload: &[u8]) {
        let len = (payload.len() + 4) as u16;
        self.0.extend_from_slice(&len.to_le_bytes());
        self.0.extend_from_slice(&ty.to_le_bytes());
        self.0.extend_from_slice(payload);
        while self.0.len() % 4 != 0 {
            self.0.push(0);
        }
    }

    pub fn attr_u32(&mut self, ty: u16, v: u32) {
        self.attr(ty, &v.to_le_bytes());
    }

    /// 接口名属性带结尾 NUL（内核按字符串解析）。
    pub fn attr_str(&mut self, ty: u16, s: &str) {
        let mut p = Vec::with_capacity(s.len() + 1);
        p.extend_from_slice(s.as_bytes());
        p.push(0);
        self.attr(ty, &p);
    }

    /// IP 属性：原始网络序字节。
    pub fn attr_ip(&mut self, ty: u16, ip: &IpAddr) {
        match ip {
            IpAddr::V4(v4) => self.attr(ty, &v4.octets()),
            IpAddr::V6(v6) => self.attr(ty, &v6.octets()),
        }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.0
    }

    pub fn into_vec(self) -> Vec<u8> {
        self.0
    }
}

/// 组装一个 netlink 消息：16 字节头 + body（body 已含子头，如 rtmsg）。
pub fn nlmsg(msg_type: u16, flags: u16, seq: u32, pid: u32, body: &[u8]) -> Vec<u8> {
    let len = (NLMSG_HDRLEN + body.len()) as u32;
    let mut out = Vec::with_capacity(len as usize);
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&msg_type.to_le_bytes());
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&pid.to_le_bytes());
    out.extend_from_slice(body);
    while out.len() % 4 != 0 {
        out.push(0);
    }
    out
}

/// 规则子头 `struct fib_rule_hdr`（12 字节）。
pub fn fib_rule_hdr(f: Family, table: u8, action: u8) -> Buf {
    let mut b = Buf::new();
    b.u8(f.af());
    b.u8(0); // dst_len
    b.u8(0); // src_len
    b.u8(0); // tos
    b.u8(table);
    b.u8(0); // res1
    b.u8(0); // res2
    b.u8(action);
    b.u32(0); // flags
    b
}

/// 路由子头 `struct rtmsg`（12 字节）。
pub fn rtmsg(f: Family, table: u8, dst_len: u8, proto: u8, scope: u8, kind: u8) -> Buf {
    let mut b = Buf::new();
    b.u8(f.af());
    b.u8(dst_len);
    b.u8(0); // src_len
    b.u8(0); // tos（DSCP 匹配现代内核已弃用，必须为 0）
    b.u8(table);
    b.u8(proto);
    b.u8(scope);
    b.u8(kind);
    b.u32(0); // rtm_flags
    b
}

/// 表号 >255 时必须写 `RTA_TABLE`，同时把头里的 `table` 置为 `RT_TABLE_UNSPEC`，
/// 这是 iproute2 的做法。
fn table_byte(table: u32) -> u8 {
    if table <= 255 {
        table as u8
    } else {
        RT_TABLE_UNSPEC
    }
}

/// 生成一条规则的安装/删除报文。
pub fn encode_rule(msg_type: u16, seq: u32, pid: u32, spec: &RuleSpec, create: bool) -> Vec<u8> {
    let mut b = fib_rule_hdr(spec.family, table_byte(spec.table), FR_ACT_TO_TBL);
    b.attr_u32(FRA_PRIORITY, spec.priority);
    if spec.fwmask != u32::MAX {
        // 只有非全 1 掩码才需要显式下发；但为了语义明确我们始终成对下发。
        b.attr_u32(FRA_FWMASK, spec.fwmask);
    }
    b.attr_u32(FRA_FWMARK, spec.fwmark);
    if spec.table > 255 {
        b.attr_u32(FRA_TABLE, spec.table);
    }
    let flags = NLM_F_REQUEST | NLM_F_ACK | if create { NLM_F_CREATE | NLM_F_EXCL } else { 0 };
    nlmsg(msg_type, flags, seq, pid, b.bytes())
}

/// 生成一条路由的安装/删除报文。
pub fn encode_route(msg_type: u16, seq: u32, pid: u32, spec: &RouteSpec, create: bool) -> Vec<u8> {
    let mut b = rtmsg(
        spec.family,
        table_byte(spec.table),
        spec.dst_len,
        OUR_RTPROT,
        spec.scope,
        spec.kind,
    );
    if let Some(d) = &spec.dst {
        b.attr_ip(RTA_DST, d);
    }
    if spec.table > 255 {
        b.attr_u32(RTA_TABLE, spec.table);
    }
    if let Some(g) = &spec.gateway {
        b.attr_ip(RTA_GATEWAY, g);
    }
    if let Some(o) = spec.oif {
        b.attr_u32(RTA_OIF, o);
    }
    if let Some(p) = &spec.prefsrc {
        b.attr_ip(RTA_PREFSRC, p);
    }
    if spec.priority != 0 {
        b.attr_u32(RTA_PRIORITY, spec.priority);
    }
    let flags = NLM_F_REQUEST | NLM_F_ACK | if create { NLM_F_CREATE | NLM_F_EXCL } else { 0 };
    nlmsg(msg_type, flags, seq, pid, b.bytes())
}

/// 地址 dump 请求（RTM_GETADDR）。`struct ifaddrmsg` 只有 8 字节。
pub fn encode_addr_dump(seq: u32, pid: u32, family: Family) -> Vec<u8> {
    let mut b = Buf::new();
    b.u8(family.af());
    b.u8(0); // prefixlen
    b.u8(0); // flags
    b.u8(0); // scope
    b.u32(0); // index
    nlmsg(RTM_GETADDR, NLM_F_REQUEST | NLM_F_DUMP, seq, pid, b.bytes())
}

/// dump 请求（RTM_GETRULE / RTM_GETROUTE）。
pub fn encode_dump(msg_type: u16, seq: u32, pid: u32, family: Family, table: u32) -> Vec<u8> {
    match msg_type {
        RTM_GETRULE => {
            let mut b = fib_rule_hdr(family, table_byte(table), FR_ACT_TO_TBL);
            if table > 255 {
                b.attr_u32(FRA_TABLE, table);
            }
            nlmsg(msg_type, NLM_F_REQUEST | NLM_F_DUMP, seq, pid, b.bytes())
        }
        _ => {
            // RTM_GETROUTE：AF_UNSPEC 时内核会同时返回 v4/v6；
            // 为了可控，我们总是按族 dump。
            let mut b = rtmsg(
                family,
                table_byte(table),
                0,
                RTPROT_UNSPEC,
                RT_SCOPE_UNIVERSE,
                RTN_UNSPEC,
            );
            if table > 255 {
                b.attr_u32(RTA_TABLE, table);
            }
            nlmsg(msg_type, NLM_F_REQUEST | NLM_F_DUMP, seq, pid, b.bytes())
        }
    }
}

// ================= 解码器（纯函数） =================

/// 属性迭代器：按 `rta_len` 前进，容忍内核新增的未知属性（跳过）。
pub struct Attrs<'a> {
    rest: &'a [u8],
}

impl<'a> Attrs<'a> {
    pub fn new(raw: &'a [u8]) -> Attrs<'a> {
        Attrs { rest: raw }
    }

    /// 取下一个属性。刻意不叫 `next`：`Attrs` 同时实现了 `Iterator`，
    /// 同名内在方法会让调用点在「内在方法」与「trait 方法」之间产生歧义（clippy 亦据此报警）。
    pub fn next_attr(&mut self) -> Option<(u16, &'a [u8])> {
        loop {
            if self.rest.len() < 4 {
                return None;
            }
            let len = u16::from_le_bytes([self.rest[0], self.rest[1]]) as usize;
            let ty = u16::from_le_bytes([self.rest[2], self.rest[3]]);
            if len < 4 || len > self.rest.len() {
                // 畸形属性：停止解析，让上层看到「解析不完整」而不是越界读。
                self.rest = &[];
                return None;
            }
            let payload = &self.rest[4..len];
            let aligned = (len + 3) & !3;
            self.rest = self.rest.get(aligned..).unwrap_or(&[]);
            if ty == RTA_UNSPEC && payload.is_empty() {
                continue;
            }
            return Some((ty, payload));
        }
    }
}

fn read_u32(p: &[u8]) -> Option<u32> {
    if p.len() < 4 {
        return None;
    }
    Some(u32::from_le_bytes([p[0], p[1], p[2], p[3]]))
}

fn read_ip(p: &[u8]) -> Option<IpAddr> {
    match p.len() {
        4 => Some(IpAddr::from(<[u8; 4]>::try_from(&p[..4]).ok()?)),
        16 => Some(IpAddr::from(<[u8; 16]>::try_from(&p[..16]).ok()?)),
        _ => None,
    }
}

fn read_cstr(p: &[u8]) -> Option<String> {
    let end = p.iter().position(|b| *b == 0).unwrap_or(p.len());
    let s = std::str::from_utf8(&p[..end]).ok()?;
    Some(s.to_string())
}

impl<'a> Iterator for Attrs<'a> {
    type Item = (u16, &'a [u8]);

    fn next(&mut self) -> Option<Self::Item> {
        self.next_attr()
    }
}

/// 解析单条规则报文（body = fib_rule_hdr + attrs）。
pub fn decode_rule_body(body: &[u8]) -> Option<RuleEntry> {
    if body.len() < 12 {
        return None;
    }
    let family = Family::from_af(body[0])?;
    let dst_len = body[1];
    let src_len = body[2];
    let table_byte = body[4];
    let action = body[7];
    let flags = u32::from_le_bytes([body[8], body[9], body[10], body[11]]);
    let mut e = RuleEntry {
        family,
        priority: 0,
        table: table_byte as u32,
        action,
        fwmark: None,
        fwmask: None,
        iifname: None,
        src: None,
        dst: None,
        protocol: None,
        flags,
    };
    for (ty, p) in Attrs::new(&body[12..]) {
        match ty {
            FRA_PRIORITY => e.priority = read_u32(p)?,
            FRA_FWMARK => e.fwmark = read_u32(p),
            FRA_FWMASK => e.fwmask = read_u32(p),
            FRA_TABLE => {
                if let Some(t) = read_u32(p) {
                    e.table = t;
                }
            }
            FRA_IIFNAME => e.iifname = read_cstr(p),
            FRA_SRC => e.src = read_ip(p).map(|ip| (ip, src_len)),
            FRA_DST => e.dst = read_ip(p).map(|ip| (ip, dst_len)),
            FRA_PROTOCOL => e.protocol = p.first().copied(),
            _ => {} // 未知属性：忽略（向前兼容更高内核）
        }
    }
    Some(e)
}

/// 解析单条路由报文（body = rtmsg + attrs）。
pub fn decode_route_body(body: &[u8]) -> Option<RouteEntry> {
    if body.len() < 12 {
        return None;
    }
    let family = Family::from_af(body[0])?;
    let dst_len = body[1];
    let table = body[4];
    let protocol = body[5];
    let scope = body[6];
    let kind = body[7];
    let mut e = RouteEntry {
        family,
        table: table as u32,
        dst_len,
        dst: None,
        gateway: None,
        oif: None,
        prefsrc: None,
        priority: 0,
        protocol,
        scope,
        kind,
    };
    for (ty, p) in Attrs::new(&body[12..]) {
        match ty {
            RTA_DST => e.dst = read_ip(p),
            RTA_GATEWAY => e.gateway = read_ip(p),
            RTA_OIF => e.oif = read_u32(p),
            RTA_PREFSRC => e.prefsrc = read_ip(p),
            RTA_PRIORITY => {
                if let Some(v) = read_u32(p) {
                    e.priority = v;
                }
            }
            RTA_TABLE => {
                if let Some(t) = read_u32(p) {
                    e.table = t;
                }
            }
            _ => {}
        }
    }
    Some(e)
}

/// 解析单条地址报文（body = ifaddrmsg(8) + attrs）。
pub fn decode_addr_body(body: &[u8]) -> Option<AddrEntry> {
    if body.len() < 8 {
        return None;
    }
    let family = Family::from_af(body[0])?;
    let prefix_len = body[1];
    let flags_low = body[2] as u32;
    let ifindex = u32::from_le_bytes([body[4], body[5], body[6], body[7]]);
    let mut addr: Option<IpAddr> = None;
    let mut local: Option<IpAddr> = None;
    let mut label: Option<String> = None;
    let mut flags = flags_low;
    for (ty, p) in Attrs::new(&body[8..]) {
        match ty {
            IFA_ADDRESS => addr = read_ip(p),
            IFA_LOCAL => local = read_ip(p),
            IFA_LABEL => label = read_cstr(p),
            // 新内核把完整 32 位 flags 放在 IFA_FLAGS 属性里，头里只剩低 8 位
            IFA_FLAGS => {
                if let Some(f) = read_u32(p) {
                    flags = f;
                }
            }
            _ => {}
        }
    }
    // 点对点链路：本机地址在 IFA_LOCAL；广播型链路只有 IFA_ADDRESS。
    let address = local.or(addr)?;
    Some(AddrEntry {
        family,
        prefix_len,
        ifindex,
        address,
        label,
        permanent: flags & IFA_F_PERMANENT != 0,
        deprecated: flags & IFA_F_DEPRECATED != 0,
        tentative: flags & IFA_F_TENTATIVE != 0,
        secondary: flags & IFA_F_SECONDARY != 0,
    })
}

/// dump 响应解析结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    Rules(Vec<RuleEntry>),
    Routes(Vec<RouteEntry>),
    Addresses(Vec<AddrEntry>),
    /// 内核对本请求的应答（NLMSG_ERROR），code=0 表示成功。
    Ack {
        error: i32,
        message: String,
    },
    Done,
}

/// 把 `recv` 收到的整段缓冲区解析为消息列表。
///
/// 返回 `Err` 只用于「缓冲区被截断/协议错乱」这类真错误；
/// 单条无法解析的消息会被跳过并计数（写日志），因为内核可能发来
/// 我们尚未认识的属性类型，此时不应该放弃整份 dump。
pub fn parse_stream(
    msg_type: u16,
    seq: u32,
    pid: u32,
    buf: &[u8],
) -> Result<(Vec<Parsed>, bool /*done*/, u32)> {
    let mut out = Vec::new();
    let mut rest = buf;
    let mut done = false;
    let mut skipped = 0u32;
    while rest.len() >= NLMSG_HDRLEN {
        let mlen = u32::from_le_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
        let mtype = u16::from_le_bytes([rest[4], rest[5]]);
        let mseq = u32::from_le_bytes([rest[8], rest[9], rest[10], rest[11]]);
        let mpid = u32::from_le_bytes([rest[12], rest[13], rest[14], rest[15]]);
        if mlen < NLMSG_HDRLEN || mlen > rest.len() {
            return Err(Error::Netlink(format!(
                "netlink 消息长度非法（声明 {mlen} 字节，缓冲剩余 {} 字节）",
                rest.len()
            )));
        }
        let body = &rest[NLMSG_HDRLEN..NLMSG_HDRLEN + mlen - NLMSG_HDRLEN];
        rest = &rest[((mlen + 3) & !3).min(rest.len())..];
        if mseq != seq || mpid != pid {
            // 属于别的会话/进程的消息：忽略，绝不拿去当成自己的 ack。
            skipped += 1;
            continue;
        }
        match mtype {
            NLMSG_ERROR => {
                // struct nlmsgerr: i32 error + 原始 16 字节请求头。
                // **成功 ACK 也是 NLMSG_ERROR（error==0）**，因此无论成败都要
                // 终结本次会话：只对 code!=0 置 done 会让每次成功写入都继续等
                // 下一条消息，直到 SO_RCVTIMEO 超时（真机集成测试实测：
                // 路由安装成功却报「netlink recv 超时」）。
                let code = i32::from_le_bytes([body[0], body[1], body[2], body[3]]);
                let desc = describe_errno(code);
                out.push(Parsed::Ack {
                    error: code,
                    message: desc,
                });
                done = true;
            }
            NLMSG_DONE => done = true,
            NLMSG_NOOP => {}
            NLMSG_OVERRUN => {
                return Err(Error::Netlink(
                    "内核报告 dump 溢出（ENOBUFS），需要重试点".into(),
                ));
            }
            t if t == msg_type => {
                if msg_type == RTM_NEWROUTE || msg_type == RTM_GETROUTE {
                    match decode_route_body(body) {
                        Some(r) => out.push(Parsed::Routes(vec![r])),
                        None => skipped += 1,
                    }
                } else if msg_type == RTM_NEWADDR || msg_type == RTM_GETADDR {
                    match decode_addr_body(body) {
                        Some(a) => out.push(Parsed::Addresses(vec![a])),
                        None => skipped += 1,
                    }
                } else {
                    match decode_rule_body(body) {
                        Some(r) => out.push(Parsed::Rules(vec![r])),
                        None => skipped += 1,
                    }
                }
            }
            _ => skipped += 1,
        }
    }
    if skipped > 0 {
        logging::warn_ctx(
            "netlink",
            "parse",
            &format!("dump 中跳过 {skipped} 条无法识别的消息"),
            &[("msg_type", msg_type.to_string())],
        );
    }
    Ok((out, done, skipped))
}

/// 把 `Parsed` 列表压平成最终结果；错误 ack 直接短路。
pub fn collect(entries: &mut Vec<Parsed>, item: Parsed) -> Result<()> {
    match item {
        Parsed::Ack { error, message } if error != 0 => {
            Err(Error::Netlink(format!("{message}（errno {error}）")))
        }
        Parsed::Ack { .. } => Ok(()),
        other => {
            entries.push(other);
            Ok(())
        }
    }
}

pub fn flatten_rules(v: Vec<Parsed>) -> Vec<RuleEntry> {
    let mut out = Vec::new();
    for p in v {
        if let Parsed::Rules(rs) = p {
            out.extend(rs);
        }
    }
    out
}

pub fn flatten_addresses(v: Vec<Parsed>) -> Vec<AddrEntry> {
    let mut out = Vec::new();
    for p in v {
        if let Parsed::Addresses(rs) = p {
            out.extend(rs);
        }
    }
    out
}

pub fn flatten_routes(v: Vec<Parsed>) -> Vec<RouteEntry> {
    let mut out = Vec::new();
    for p in v {
        if let Parsed::Routes(rs) = p {
            out.extend(rs);
        }
    }
    out
}

/// 按路由表号过滤 dump 结果。内核的 `RTM_GETROUTE` dump 不按请求的 `rtm_table`
/// 过滤（实测请求 101 也返回 main/local 的路由），所以每一张表的 dump 都要在
/// 客户端按响应消息自带的 `rtm_table` 收窄一次。
///
/// 不过滤的后果不是「多一点数据」：按 24 张表循环 dump 时，表 101 的路由会被
/// 收进 24 份，`route::reconcile` 据此产生 24 条重复删除 —— 第一次成功、
/// 其余 ESRCH，整个回收失败（真机集成测试实测，沙箱替身不经过这条路所以没暴露）。
pub fn filter_routes_by_table(routes: Vec<RouteEntry>, table: u32) -> Vec<RouteEntry> {
    routes.into_iter().filter(|r| r.table == table).collect()
}

/// errno 文本：只翻译我们确实会遇到的几个，其它给通用描述。
fn describe_errno(code: i32) -> String {
    // 内核返回的是负的 errno。
    let e = -code;
    match e {
        1 => "EPERM：权限不足，smartmwand 必须以 root 运行".to_string(),
        2 => "ENOENT：对象不存在（规则或路由已被他人删除）".to_string(),
        13 => "EACCES：访问被拒绝".to_string(),
        17 => "EEXIST：同优先级/同表的对象已存在（可能与其它组件冲突）".to_string(),
        22 => "EINVAL：内核拒绝了参数（优先级、掩码或表号非法）".to_string(),
        28 => "ENOSPC：内核对象数量达到上限".to_string(),
        85 => "EOPNOTSUPP：内核未开启相应功能".to_string(),
        90 => "ENOBUFS：dump 期间事件缓冲溢出".to_string(),
        95 => "EOPNOTSUPP：该地址族或操作不被支持".to_string(),
        other => format!("errno {other}"),
    }
}

// ================= 连接 =================

/// netlink dump/变更请求的默认接收超时。
///
/// 现代路由 SoC 上百毫秒就能 dump 完整张表，给 2 秒是为了在极端负载下
/// 仍然「明确失败」而不是永久挂起——守护进程宁可报超时也不能卡死选路循环。
pub const DEFAULT_RECV_TIMEOUT_MS: u64 = 2000;

/// netlink 的异步门面。
///
/// 设计取舍：一条 netlink socket 上的 dump 不能交错（seq/pid 会串扰），
/// 因此这里用 `Mutex<Connection>` + `spawn_blocking`：
/// * 请求在阻塞线程里排队执行，绝不占用 tokio 工作线程；
/// * `Mutex` 就是并发互斥点，语义与「一次只做一件内核改动」一致；
/// * 锁中毒（此前有 panic）会被明确报成错误，不会静默复用坏连接。
#[derive(Clone)]
pub struct NetlinkHandle {
    inner: std::sync::Arc<Mutex<Connection>>,
}

impl NetlinkHandle {
    /// 打开连接并交给门面。没有权限时直接返回错误，由调用方决定降级方式。
    pub fn open(recv_timeout: Duration) -> Result<NetlinkHandle> {
        Ok(NetlinkHandle {
            inner: std::sync::Arc::new(Mutex::new(Connection::open(recv_timeout)?)),
        })
    }

    async fn run<T>(&self, f: impl FnOnce(&Connection) -> Result<T> + Send + 'static) -> Result<T>
    where
        T: Send + 'static,
    {
        let c = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let guard = c.lock().map_err(|_| {
                Error::Netlink("netlink 互斥锁中毒：此前有 panic 破坏了连接，需重启服务".into())
            })?;
            f(&guard)
        })
        .await
        .map_err(|e| Error::Netlink(format!("netlink 阻塞任务被丢弃: {e}")))?
    }

    /// 已在阻塞线程内的同步访问。锁中毒必须报出来：那意味着连接状态不可信。
    pub fn sync<T>(&self, f: impl FnOnce(&Connection) -> T) -> Result<T> {
        let guard = self.inner.lock().map_err(|_| {
            Error::Netlink("netlink 互斥锁中毒：此前有 panic 破坏了连接，需重启服务".into())
        })?;
        Ok(f(&guard))
    }

    pub async fn dump_rules(&self, family: Family) -> Result<Vec<RuleEntry>> {
        self.run(move |c| c.dump_rules(family)).await
    }

    pub async fn dump_routes(&self, family: Family, table: u32) -> Result<Vec<RouteEntry>> {
        self.run(move |c| c.dump_routes(family, table)).await
    }

    pub async fn dump_addresses(&self, family: Family) -> Result<Vec<AddrEntry>> {
        self.run(move |c| c.dump_addresses(family)).await
    }

    pub async fn add_rule(&self, spec: RuleSpec) -> Result<()> {
        self.run(move |c| c.add_rule(&spec)).await
    }

    pub async fn del_rule(&self, spec: RuleSpec) -> Result<()> {
        self.run(move |c| c.del_rule(&spec)).await
    }

    pub async fn add_route(&self, spec: RouteSpec) -> Result<()> {
        self.run(move |c| c.add_route(&spec)).await
    }

    pub async fn del_route(&self, spec: RouteSpec) -> Result<()> {
        self.run(move |c| c.del_route(&spec)).await
    }
}

/// 同步视图：给已经在 `spawn_blocking` 里运行的代码用（例如 observe 的整轮只读扫描）。
///
/// 与 async 方法共用同一把锁，因此「读一轮内核」天然是原子的快照。
pub struct BlockingOps<'a>(pub &'a NetlinkHandle);

impl RouteOps for BlockingOps<'_> {
    fn dump_rules(&self, family: Family) -> Result<Vec<RuleEntry>> {
        self.0.sync(|c| c.dump_rules(family))?
    }

    fn dump_routes(&self, family: Family, table: u32) -> Result<Vec<RouteEntry>> {
        self.0.sync(|c| c.dump_routes(family, table))?
    }

    fn dump_addresses(&self, family: Family) -> Result<Vec<AddrEntry>> {
        self.0.sync(|c| c.dump_addresses(family))?
    }

    fn add_rule(&self, spec: &RuleSpec) -> Result<()> {
        self.0.sync(|c| c.add_rule(spec))?
    }

    fn del_rule(&self, spec: &RuleSpec) -> Result<()> {
        self.0.sync(|c| c.del_rule(spec))?
    }

    fn add_route(&self, spec: &RouteSpec) -> Result<()> {
        self.0.sync(|c| c.add_route(spec))?
    }

    fn del_route(&self, spec: &RouteSpec) -> Result<()> {
        self.0.sync(|c| c.del_route(spec))?
    }
}

/// 拥有句柄的 `RouteOps` 实现（生产路径）。
///
/// 为什么不是直接给 `NetlinkHandle` 实现 trait：`NetlinkHandle` 上已有一组同名 **async**
/// 方法， inherent 方法优先于 trait 方法， concrete 类型上调用到的会是 async 那个，
/// 极易误用。这里用一个新类型显式表达「我要同步视图」，并且它能装进
/// `Arc<dyn RouteOps>`（`BlockingOps` 借用句柄，做不到）。
///
/// 语义与 [`BlockingOps`] 完全一致：每个方法都在同一把互斥锁下做一次内核操作。
/// 调用方必须已经处在 `spawn_blocking`（或另一个阻塞线程）里，否则会把 tokio
/// 工作线程压在锁上。
#[derive(Clone)]
pub struct HandleOps(pub NetlinkHandle);

impl RouteOps for HandleOps {
    fn dump_rules(&self, family: Family) -> Result<Vec<RuleEntry>> {
        self.0.sync(|c| c.dump_rules(family))?
    }

    fn dump_routes(&self, family: Family, table: u32) -> Result<Vec<RouteEntry>> {
        self.0.sync(|c| c.dump_routes(family, table))?
    }

    fn dump_addresses(&self, family: Family) -> Result<Vec<AddrEntry>> {
        self.0.sync(|c| c.dump_addresses(family))?
    }

    fn add_rule(&self, spec: &RuleSpec) -> Result<()> {
        self.0.sync(|c| c.add_rule(spec))?
    }

    fn del_rule(&self, spec: &RuleSpec) -> Result<()> {
        self.0.sync(|c| c.del_rule(spec))?
    }

    fn add_route(&self, spec: &RouteSpec) -> Result<()> {
        self.0.sync(|c| c.add_route(spec))?
    }

    fn del_route(&self, spec: &RouteSpec) -> Result<()> {
        self.0.sync(|c| c.del_route(spec))?
    }
}

/// 阻塞式 netlink 连接，靠 `SO_RCVTIMEO`/`SO_SNDTIMEO` 保证不会永久挂起。
///
/// 调用方必须在 `tokio::task::spawn_blocking` 里使用它（见 `system::mod::blocking`），
/// 这样既不阻塞 async 执行器，也不需要给 socket 引入 AsyncFd 的复杂度。
pub struct Connection {
    fd: OwnedFd,
    seq: std::sync::atomic::AtomicU32,
    recv_timeout: Duration,
}

impl Connection {
    pub fn open(recv_timeout: Duration) -> Result<Connection> {
        if !cfg!(target_endian = "little") {
            return Err(Error::Unsupported(
                "本机不是小端架构，本插件的 netlink 编码未针对大端验证过，拒绝运行".into(),
            ));
        }
        // SAFETY: 创建的是标准 NETLINK_ROUTE datagram socket，失败返回 -1。
        let raw = unsafe {
            libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_RAW | libc::SOCK_CLOEXEC,
                NETLINK_ROUTE,
            )
        };
        if raw < 0 {
            let e = std::io::Error::last_os_error();
            return Err(Error::Netlink(format!("打开 NETLINK_ROUTE 失败: {e}")));
        }
        // SAFETY: fd 有效；sockaddr_nl 是 POD，清零后填字段。
        let bind_res = unsafe {
            let mut addr: libc::sockaddr_nl = std::mem::zeroed();
            addr.nl_family = libc::AF_NETLINK as u16;
            addr.nl_pid = std::process::id();
            addr.nl_groups = 0; // 不订阅组播：本插件全部走按需 dump，避免背压丢包
            libc::bind(
                raw,
                &addr as *const libc::sockaddr_nl as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_nl>() as u32,
            )
        };
        if bind_res < 0 {
            let e = std::io::Error::last_os_error();
            // SAFETY: 关闭刚创建的 fd。
            unsafe {
                libc::close(raw);
            }
            return Err(Error::Netlink(format!("bind netlink 失败: {e}")));
        }
        let f = recv_timeout.to_std_timeout();
        // SAFETY: setsockopt 传 timeval 结构，fd 有效。
        //
        // 三个必须记住的坑（都踩过）：
        // 1. `SO_RCVTIMEO`/`SO_SNDTIMEO`/`SO_RCVBUF` 都是 **SOL_SOCKET** 层的选项，
        //    写到 SOL_NETLINK 会 ENOPROTOOPT 静默失败 —— 没有超时的 netlink recv
        //    会在内核不回复时**永久挂住**整个 spawn_blocking 线程（真机集成测试
        //    里主循环卡死、探测轮全停，就是这么来的）；
        // 2. `tv_usec` 本来就是微秒，`subsec_micros()` 不能再乘 1000；
        // 3. 返回值必须检查：超时设不上就等于把「挂住」当默认行为，必须致命。
        unsafe {
            // 经 i64 中转但不点出 `libc::time_t`/`suseconds_t` 别名：musl 1.2.0
            // 起这两个别名将变为 64 位并标记弃用，点名会在一目标上刷警告。
            // 语义不变（两侧都是足够宽的整数），glibc 目标同样编译通过。
            let tv = libc::timeval {
                tv_sec: i64::try_from(f.as_secs()).unwrap_or(i64::MAX) as _,
                tv_usec: i64::from(f.subsec_micros()) as _,
            };
            for (name, opt) in [
                ("SO_RCVTIMEO", libc::SO_RCVTIMEO),
                ("SO_SNDTIMEO", libc::SO_SNDTIMEO),
            ] {
                let r = libc::setsockopt(
                    raw,
                    libc::SOL_SOCKET,
                    opt,
                    &tv as *const libc::timeval as *const libc::c_void,
                    std::mem::size_of::<libc::timeval>() as libc::socklen_t,
                );
                if r != 0 {
                    let e = std::io::Error::last_os_error();
                    libc::close(raw);
                    return Err(Error::Netlink(format!(
                        "设置 netlink {name} 失败: {e}（没有超时保护的 netlink 会永久挂起，拒绝继续）"
                    )));
                }
            }
            // 接收缓冲调大，降低 dump 期间 ENOBUFS 概率。设不上只是优化失效，可容忍。
            let bufsize: libc::c_int = 1 << 20;
            libc::setsockopt(
                raw,
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                &bufsize as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
        // SAFETY: fd 由本 OwnedFd 独占管理。
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        Ok(Connection {
            fd,
            seq: std::sync::atomic::AtomicU32::new(1),
            recv_timeout,
        })
    }

    fn next_seq(&self) -> u32 {
        self.seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed) & 0x7fff_ffff
    }

    /// 发送一个请求并读取应答直到 done/ack。
    fn request(&self, msg: &[u8], expect_type: u16, seq: u32) -> Result<(Vec<Parsed>, bool)> {
        let fd = self.fd.as_raw_fd();
        let mut sent = 0usize;
        while sent < msg.len() {
            // SAFETY: write 到已连接 netlink socket。
            let n = unsafe {
                libc::send(
                    fd,
                    msg[sent..].as_ptr() as *const libc::c_void,
                    msg.len() - sent,
                    libc::MSG_DONTWAIT | libc::MSG_NOSIGNAL,
                )
            };
            if n < 0 {
                let e = std::io::Error::last_os_error();
                if e.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                if e.kind() == std::io::ErrorKind::WouldBlock {
                    return Err(Error::Timeout {
                        operation: "netlink send".into(),
                        elapsed_ms: 0,
                    });
                }
                return Err(Error::Netlink(format!("send 失败: {e}")));
            }
            sent += n as usize;
        }

        let mut acc = Vec::new();
        let mut buf = vec![0u8; 65536];
        let mut done = false;
        // 最多读 64 次，防止内核持续推消息时这里变成无限循环。
        for _ in 0..64 {
            // SAFETY: recv 到有效缓冲区。
            let n = unsafe { libc::recv(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };
            if n < 0 {
                let e = std::io::Error::last_os_error();
                return match e.raw_os_error() {
                    Some(libc::EAGAIN) | Some(libc::ETIMEDOUT) => Err(Error::Timeout {
                        operation: format!("netlink recv（{}ms）", self.recv_timeout.as_millis()),
                        elapsed_ms: self.recv_timeout.as_millis() as u64,
                    }),
                    Some(libc::EINTR) => continue,
                    Some(libc::ENOBUFS) => Err(Error::Netlink(
                        "recv ENOBUFS：dump 期间内核事件缓冲溢出".into(),
                    )),
                    _ => Err(Error::Netlink(format!("recv 失败: {e}"))),
                };
            }
            let (parsed, is_done, _skipped) =
                parse_stream(expect_type, seq, std::process::id(), &buf[..n as usize])?;
            for p in parsed {
                let err = match &p {
                    Parsed::Ack { error, .. } => *error != 0,
                    _ => false,
                };
                collect(&mut acc, p)?;
                if err {
                    return Ok((acc, true));
                }
            }
            if is_done {
                done = true;
                break;
            }
        }
        if !done {
            logging::warn_ctx(
                "netlink",
                "dump",
                "dump 达到读取次数上限，结果可能不完整",
                &[],
            );
        }
        Ok((acc, done))
    }

    /// 执行一个变更类请求（add/del），把非零 errno 变成错误。
    fn transact(&self, msg: &[u8], seq: u32) -> Result<()> {
        let (acc, _) = self.request(msg, 0, seq)?;
        for p in acc {
            if let Parsed::Ack { error, message } = p {
                if error != 0 {
                    return Err(Error::Netlink(message.to_string()));
                }
            }
        }
        Ok(())
    }

    pub fn dump_rules_conn(&self, family: Family) -> Result<Vec<RuleEntry>> {
        let seq = self.next_seq();
        let msg = encode_dump(RTM_GETRULE, seq, std::process::id(), family, 0);
        let (acc, _) = self.request(&msg, RTM_NEWRULE, seq)?;
        Ok(flatten_rules(acc))
    }

    pub fn dump_routes_conn(&self, family: Family, table: u32) -> Result<Vec<RouteEntry>> {
        let seq = self.next_seq();
        let msg = encode_dump(RTM_GETROUTE, seq, std::process::id(), family, table);
        let (acc, _) = self.request(&msg, RTM_NEWROUTE, seq)?;
        // 内核的 RTM_GETROUTE dump **不按请求里的 rtm_table 过滤**（实测：请求
        // rtm_table=101 会连 main/local 表的路由一起返回）。必须在客户端按响应
        // 消息自带的 rtm_table 过滤，否则「按 24 张表各 dump 一遍」会把表 101 的
        // 路由收进 24 份，reconcile 据此产生 24 条重复删除 —— 第一次成功，
        // 其余全部 ESRCH，回收/收敛整体失败（真机集成测试实测）。
        Ok(filter_routes_by_table(flatten_routes(acc), table))
    }
}

impl RouteOps for Connection {
    fn dump_rules(&self, family: Family) -> Result<Vec<RuleEntry>> {
        self.dump_rules_conn(family)
    }

    fn dump_routes(&self, family: Family, table: u32) -> Result<Vec<RouteEntry>> {
        self.dump_routes_conn(family, table)
    }

    fn dump_addresses(&self, family: Family) -> Result<Vec<AddrEntry>> {
        let seq = self.next_seq();
        let msg = encode_addr_dump(seq, std::process::id(), family);
        let (acc, _) = self.request(&msg, RTM_NEWADDR, seq)?;
        Ok(flatten_addresses(acc))
    }

    fn add_rule(&self, spec: &RuleSpec) -> Result<()> {
        let seq = self.next_seq();
        let msg = encode_rule(RTM_NEWRULE, seq, std::process::id(), spec, true);
        self.transact(&msg, seq)
    }

    fn del_rule(&self, spec: &RuleSpec) -> Result<()> {
        let seq = self.next_seq();
        let msg = encode_rule(RTM_DELRULE, seq, std::process::id(), spec, false);
        self.transact(&msg, seq)
    }

    fn add_route(&self, spec: &RouteSpec) -> Result<()> {
        let seq = self.next_seq();
        let msg = encode_route(RTM_NEWROUTE, seq, std::process::id(), spec, true);
        self.transact(&msg, seq)
    }

    fn del_route(&self, spec: &RouteSpec) -> Result<()> {
        let seq = self.next_seq();
        let msg = encode_route(RTM_DELROUTE, seq, std::process::id(), spec, false);
        self.transact(&msg, seq)
    }
}

/// `Duration` 到内核 timeval 的转换上限：内核不接受负值，也不该接受 0（等于关闭超时）。
trait ToStdTimeout {
    fn to_std_timeout(&self) -> Duration;
}

impl ToStdTimeout for Duration {
    fn to_std_timeout(&self) -> Duration {
        // 至少 1ms，避免 tv=0 变成「立即超时」或「永久等待」的歧义。
        (*self).max(Duration::from_millis(1))
    }
}

/// 从 sysfs 读接口索引；比 `if_nametoindex` 更明确地失败（不依赖 libc 版本）。
pub fn ifindex(name: &str, sysfs_root: &std::path::Path) -> Result<u32> {
    if name.is_empty() || name.len() > 15 || name.contains('/') || name.contains('\0') {
        return Err(Error::Validate(format!("非法接口名: {name}")));
    }
    let p = sysfs_root.join(name).join("ifindex");
    let text = std::fs::read_to_string(&p)
        .map_err(|e| Error::Netlink(format!("读取 {} 失败: {e}", p.display())))?;
    let v: u32 = text.trim().parse().map_err(|_| {
        Error::Netlink(format!(
            "{} 内容非法: {:?}",
            p.display(),
            crate::clamp_str(&text, 32)
        ))
    })?;
    if v == 0 {
        return Err(Error::Netlink(format!("接口 {name} 的 ifindex 为 0")));
    }
    Ok(v)
}

/// 测试用替身：记录所有变更请求，返回预置的 dump 内容。
///
/// 有了它，`route::reconcile` 的收敛逻辑（增删顺序、失败回滚、冲突审计）
/// 可以在普通用户权限下完整测试；真机行为由 `docs/testing.md` 的设备验证清单覆盖。
#[derive(Debug, Default)]
pub struct FakeNetlink {
    rules: Mutex<Vec<RuleEntry>>,
    routes: Mutex<Vec<RouteEntry>>,
    addresses: Mutex<Vec<AddrEntry>>,
    /// 依次弹出注入的错误，用来测试失败/回滚路径。
    pub fail_add_rule: Mutex<Vec<Option<String>>>,
    pub fail_add_route: Mutex<Vec<Option<String>>>,
    pub fail_del_rule: Mutex<Vec<Option<String>>>,
    pub fail_del_route: Mutex<Vec<Option<String>>>,
    log: Mutex<Vec<String>>,
}

impl FakeNetlink {
    pub fn new() -> FakeNetlink {
        FakeNetlink::default()
    }

    /// 预置内核现状：dump 就返回这些（RouteOps 需要 `&self`，因此内部用锁）。
    pub fn with_state(
        rules: Vec<RuleEntry>,
        routes: Vec<RouteEntry>,
        addresses: Vec<AddrEntry>,
    ) -> FakeNetlink {
        FakeNetlink {
            rules: Mutex::new(rules),
            routes: Mutex::new(routes),
            addresses: Mutex::new(addresses),
            ..Default::default()
        }
    }

    pub fn rule_list(&self) -> Vec<RuleEntry> {
        lock(&self.rules).clone()
    }

    pub fn route_list(&self) -> Vec<RouteEntry> {
        lock(&self.routes).clone()
    }

    pub fn addr_list(&self) -> Vec<AddrEntry> {
        lock(&self.addresses).clone()
    }

    /// 清空全部状态，用来模拟「外部组件把我们的对象删掉了」。
    pub fn clear(&self) {
        lock(&self.rules).clear();
        lock(&self.routes).clear();
        lock(&self.addresses).clear();
    }

    /// 只清规则：模拟 `ip rule del` 被别的组件执行过。
    pub fn clear_rules(&self) {
        lock(&self.rules).clear();
    }

    /// 注入错误队列（按调用顺序弹出）。
    pub fn fail_rules(&self, errs: Vec<Option<String>>) {
        *lock(&self.fail_add_rule) = errs;
    }

    pub fn fail_routes(&self, errs: Vec<Option<String>>) {
        *lock(&self.fail_add_route) = errs;
    }

    pub fn fail_del_rules(&self, errs: Vec<Option<String>>) {
        *lock(&self.fail_del_rule) = errs;
    }

    fn record(&self, s: String) {
        if let Ok(mut g) = self.log.lock() {
            g.push(s);
        }
    }

    pub fn logged(&self) -> Vec<String> {
        self.log.lock().map(|g| g.clone()).unwrap_or_default()
    }

    fn take_fail(&self, q: &Mutex<Vec<Option<String>>>) -> Result<()> {
        let mut g = q
            .lock()
            .map_err(|_| Error::Netlink("fake 状态锁中毒".into()))?;
        if g.is_empty() {
            return Ok(());
        }
        match g.remove(0) {
            Some(m) => Err(Error::Netlink(m)),
            None => Ok(()),
        }
    }
}

/// 统一的加锁读取：中毒的锁在测试替身里意味着测试本身写坏了，直接 panic 比静默跳过好。
fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().expect("FakeNetlink 内部锁中毒")
}

impl RouteOps for FakeNetlink {
    fn dump_rules(&self, family: Family) -> Result<Vec<RuleEntry>> {
        Ok(lock(&self.rules)
            .iter()
            .filter(|r| r.family == family)
            .cloned()
            .collect())
    }

    fn dump_routes(&self, family: Family, table: u32) -> Result<Vec<RouteEntry>> {
        Ok(lock(&self.routes)
            .iter()
            .filter(|r| r.family == family && r.table == table)
            .cloned()
            .collect())
    }

    fn dump_addresses(&self, family: Family) -> Result<Vec<AddrEntry>> {
        Ok(lock(&self.addresses)
            .iter()
            .filter(|a| a.family == family)
            .cloned()
            .collect())
    }

    fn add_rule(&self, spec: &RuleSpec) -> Result<()> {
        self.record(format!(
            "add_rule {:?}:prio {} fw 0x{:02x}/0x{:02x} table {}",
            spec.family, spec.priority, spec.fwmark, spec.fwmask, spec.table
        ));
        self.take_fail(&self.fail_add_rule)?;
        let e = RuleEntry {
            family: spec.family,
            priority: spec.priority,
            table: spec.table,
            action: FR_ACT_TO_TBL,
            fwmark: Some(spec.fwmark),
            fwmask: Some(spec.fwmask),
            iifname: None,
            src: None,
            dst: None,
            protocol: Some(OUR_RTPROT),
            flags: 0,
        };
        let mut g = lock(&self.rules);
        g.retain(|r| !(r.family == spec.family && r.priority == spec.priority));
        g.push(e);
        Ok(())
    }

    fn del_rule(&self, spec: &RuleSpec) -> Result<()> {
        self.record(format!("del_rule {:?}:prio {}", spec.family, spec.priority));
        self.take_fail(&self.fail_del_rule)?;
        let mut g = lock(&self.rules);
        g.retain(|r| {
            !(r.family == spec.family
                && r.priority == spec.priority
                && r.fwmark == Some(spec.fwmark))
        });
        Ok(())
    }

    fn add_route(&self, spec: &RouteSpec) -> Result<()> {
        self.record(format!(
            "add_route {:?} table {} dst {}",
            spec.family,
            spec.table,
            spec.dst
                .map(|d| d.to_string())
                .unwrap_or_else(|| "default".into())
        ));
        self.take_fail(&self.fail_add_route)?;
        let e = RouteEntry {
            family: spec.family,
            table: spec.table,
            dst_len: spec.dst_len,
            dst: spec.dst,
            gateway: spec.gateway,
            oif: spec.oif,
            prefsrc: spec.prefsrc,
            priority: spec.priority,
            protocol: OUR_RTPROT,
            scope: spec.scope,
            kind: spec.kind,
        };
        let mut g = lock(&self.routes);
        g.retain(|r| {
            !(r.family == spec.family
                && r.table == spec.table
                && r.dst == spec.dst
                && r.dst_len == spec.dst_len)
        });
        g.push(e);
        Ok(())
    }

    fn del_route(&self, spec: &RouteSpec) -> Result<()> {
        self.record(format!("del_route {:?} table {}", spec.family, spec.table));
        self.take_fail(&self.fail_del_route)?;
        let mut g = lock(&self.routes);
        g.retain(|r| {
            !(r.family == spec.family
                && r.table == spec.table
                && r.dst == spec.dst
                && r.dst_len == spec.dst_len)
        });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn constants_match_kernel_uapi() {
        // 这些值如果写错，数据平面会静默装错规则，因此用测试把 UAPI 钉住。
        assert_eq!(NLMSG_HDRLEN, 16);
        assert_eq!(RTM_NEWROUTE, 24);
        assert_eq!(RTM_GETRULE, 34);
        assert_eq!(FRA_PRIORITY, 6);
        assert_eq!(FRA_FWMARK, 10);
        assert_eq!(FRA_FWMASK, 16);
        assert_eq!(FRA_TABLE, 15);
        assert_eq!(RTA_GATEWAY, 5);
        assert_eq!(RTA_TABLE, 15);
        assert_eq!(RT_TABLE_MAIN, 254);
        assert_eq!(RT_TABLE_LOCAL, 255);
        assert_eq!(RTN_LOCAL, 2);
        assert_eq!(RTN_THROW, 9);
        assert_eq!(RTPROT_STATIC, 4);
        assert_eq!(AF_INET, 2);
        assert_eq!(AF_INET6, 10);
        assert_eq!(FR_ACT_TO_TBL, 1);
    }

    #[test]
    fn header_sizes_are_twelve_bytes() {
        // rtmsg 与 fib_rule_hdr 都是 12 字节（末尾 u32 flags）。
        let b = rtmsg(
            Family::V4,
            RT_TABLE_MAIN,
            0,
            RTPROT_UNSPEC,
            RT_SCOPE_UNIVERSE,
            RTN_UNSPEC,
        );
        assert_eq!(b.bytes().len(), 12);
        let r = fib_rule_hdr(Family::V6, 0, FR_ACT_TO_TBL);
        assert_eq!(r.bytes().len(), 12);
    }

    #[test]
    fn encodes_rule_request_layout() {
        let spec = RuleSpec {
            family: Family::V4,
            priority: 1001,
            table: 101,
            fwmark: 1,
            fwmask: 0xff,
        };
        let m = encode_rule(RTM_NEWRULE, 7, 4242, &spec, true);
        let len = u32::from_le_bytes([m[0], m[1], m[2], m[3]]) as usize;
        assert_eq!(len, m.len(), "nlmsglen 必须等于实际长度");
        assert!(len % 4 == 0);
        assert_eq!(u16::from_le_bytes([m[4], m[5]]), RTM_NEWRULE);
        let flags = u16::from_le_bytes([m[6], m[7]]);
        assert_eq!(flags & NLM_F_REQUEST, NLM_F_REQUEST);
        assert_eq!(flags & NLM_F_ACK, NLM_F_ACK);
        assert_eq!(flags & NLM_F_CREATE, NLM_F_CREATE);
        assert_eq!(flags & NLM_F_EXCL, NLM_F_EXCL);
        assert_eq!(u32::from_le_bytes([m[8], m[9], m[10], m[11]]), 7);
        assert_eq!(m[16], AF_INET, "子头 family 在 body 首字节");
        assert_eq!(m[16 + 4], 101, "表号在头里（<=255）");
        assert_eq!(m[16 + 7], FR_ACT_TO_TBL);
        // 回环解析
        let e = decode_rule_body(&m[16..]).expect("可解析");
        assert_eq!(e.priority, 1001);
        assert_eq!(e.table, 101);
        assert_eq!(e.fwmark, Some(1));
        assert_eq!(e.fwmask, Some(0xff));
    }

    #[test]
    fn table_over_255_uses_rta_table() {
        let spec = RouteSpec {
            family: Family::V4,
            table: 1001,
            dst: None,
            dst_len: 0,
            gateway: Some(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))),
            oif: Some(7),
            prefsrc: Some(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2))),
            kind: RTN_UNICAST,
            scope: RT_SCOPE_LINK,
            priority: 1024,
        };
        let m = encode_route(RTM_NEWROUTE, 3, 1, &spec, true);
        let e = decode_route_body(&m[16..]).unwrap();
        assert_eq!(e.table, 1001);
        assert_eq!(e.gateway, Some(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))));
        assert_eq!(e.oif, Some(7));
        assert_eq!(e.prefsrc, Some(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2))));
        assert!(e.is_default());
        assert_eq!(e.prefix_text(), "default");
    }

    #[test]
    fn encodes_ipv6_address_as_raw_octets() {
        let gw: IpAddr = "fe80::2".parse().unwrap();
        let mut b = Buf::new();
        b.attr_ip(RTA_GATEWAY, &gw);
        assert_eq!(b.bytes().len(), 4 + 16);
        let (ty, p) = Attrs::new(b.bytes()).next().unwrap();
        assert_eq!(ty, RTA_GATEWAY);
        assert_eq!(read_ip(p), Some(gw));
    }

    #[test]
    fn roundtrip_dump_stream() {
        // 构造两条 RTM_NEWROUTE + DONE 的完整 dump 缓冲。
        let mk = |table: u32, ip: &str| -> Vec<u8> {
            let spec = RouteSpec {
                family: Family::V4,
                table,
                dst: Some(ip.parse().unwrap()),
                dst_len: 24,
                gateway: None,
                oif: Some(3),
                prefsrc: None,
                kind: RTN_UNICAST,
                scope: RT_SCOPE_LINK,
                priority: 0,
            };
            encode_route(RTM_NEWROUTE, 9, 4242, &spec, true)
        };
        let mut buf = mk(101, "192.168.1.0");
        buf.extend_from_slice(&mk(102, "10.10.0.0"));
        // DONE 报文
        let done_body: Vec<u8> = vec![0; 4];
        let mut done = nlmsg(NLMSG_DONE, 0, 9, 4242, &done_body);
        // nlmsg 会按 4 对齐，DONE 只需头 + 可选 4 字节
        buf.append(&mut done);
        let (parsed, is_done, _s) = parse_stream(RTM_NEWROUTE, 9, 4242, &buf).unwrap();
        assert!(is_done);
        assert_eq!(flatten_routes(parsed).len(), 2);
    }

    #[test]
    fn success_ack_terminates_the_session() {
        // 回归：内核的成功 ACK 是 NLMSG_ERROR + error==0。解析器曾只对
        // error!=0 置 done，于是每次**成功**的 netlink 写入都会继续等下一条
        // 消息直到超时（真机上表现为「装是装上了，但报 recv 超时」）。
        // 构造 error=0 的 ACK：nlmsgerr 体 = i32(0) + 16 字节原始请求头。
        let mut body = 0i32.to_le_bytes().to_vec();
        body.extend_from_slice(&[0u8; 16]);
        let m = nlmsg(NLMSG_ERROR, 0, 7, 4242, &body);
        let (parsed, done, _s) = parse_stream(RTM_NEWROUTE, 7, 4242, &m).unwrap();
        assert!(done, "成功 ACK 必须终结会话");
        match parsed.as_slice() {
            [Parsed::Ack { error, .. }] => assert_eq!(*error, 0),
            other => panic!("应解析出一条 Ack，实际 {other:?}"),
        }
    }

    #[test]
    fn route_dump_results_are_filtered_by_table() {
        // 回归：内核的 RTM_GETROUTE dump 不按请求的 rtm_table 过滤。构造一条
        // 「表 101 的默认路由 + 一条 main 表路由」的 dump 响应，filter 必须
        // 只留下表 101 的那条 —— 否则按 24 张表循环 dump 会重复收录，
        // reconcile 产生重复删除（第二次起 ESRCH，真机实测）。
        let mk = |table: u32, dst: Option<&str>, dst_len: u8, proto: u8| -> RouteEntry {
            RouteEntry {
                family: Family::V4,
                table,
                dst: dst.map(|s| s.parse().unwrap()),
                dst_len,
                gateway: None,
                oif: Some(2),
                prefsrc: None,
                priority: 0,
                protocol: proto,
                scope: RT_SCOPE_LINK,
                kind: RTN_UNICAST,
            }
        };
        let all = vec![
            mk(254, Some("192.168.100.0"), 24, RTPROT_KERNEL),
            mk(101, None, 0, OUR_RTPROT),
            mk(255, Some("127.0.0.1"), 32, RTPROT_KERNEL),
            mk(101, Some("192.168.100.20"), 32, OUR_RTPROT),
        ];
        let kept = filter_routes_by_table(all, 101);
        assert_eq!(kept.len(), 2, "只应留下表 101 的路由");
        assert!(kept.iter().all(|r| r.table == 101));
        assert!(kept.iter().any(|r| r.dst.is_none()), "默认路由应在结果里");
        // 空表号请求不得把别人的表收进来
        assert!(filter_routes_by_table(vec![mk(254, None, 0, RTPROT_KERNEL)], 101).is_empty());
    }

    #[test]
    fn ignores_messages_from_other_sessions() {
        let spec = RuleSpec {
            family: Family::V4,
            priority: 1000,
            table: 100,
            fwmark: 0,
            fwmask: 0xff,
        };
        let m = encode_rule(RTM_NEWRULE, 11, 99, &spec, true);
        let (parsed, done, skipped) = parse_stream(RTM_NEWRULE, 12, 4242, &m).unwrap();
        assert_eq!(skipped, 1);
        assert!(!done);
        assert!(
            parsed.is_empty(),
            "seq/pid 不匹配的消息绝不能当成自己的结果"
        );
    }

    #[test]
    fn truncated_attribute_does_not_panic() {
        // 声明长度超过实际的属性：必须停止解析而不是越界。
        let mut b = Buf::new();
        b.0.extend_from_slice(&200u16.to_le_bytes());
        b.0.extend_from_slice(&(FRA_PRIORITY).to_le_bytes());
        b.0.extend_from_slice(&[1, 2, 3]);
        let mut it = Attrs::new(b.bytes());
        assert!(it.next().is_none());
    }

    #[test]
    fn unknown_attributes_are_skipped() {
        let mut hdr = fib_rule_hdr(Family::V4, 100, FR_ACT_TO_TBL);
        hdr.attr_u32(200, 7); // 未来内核才有的属性
        hdr.attr_u32(FRA_PRIORITY, 3000);
        let m = nlmsg(RTM_NEWRULE, 0, 1, 1, hdr.bytes());
        let e = decode_rule_body(&m[16..]).expect("可解析");
        assert_eq!(e.priority, 3000);
    }

    #[test]
    fn error_ack_is_reported_with_readable_code() {
        assert!(describe_errno(-1).contains("EPERM"));
        assert!(describe_errno(-17).contains("EEXIST"));
        assert!(describe_errno(-1000).contains("errno"));
        let mut acc = Vec::new();
        let r = collect(
            &mut acc,
            Parsed::Ack {
                error: -1,
                message: "EPERM".into(),
            },
        );
        assert!(matches!(r, Err(Error::Netlink(_))));
    }

    #[test]
    fn bad_message_length_is_error_not_panic() {
        let mut m = nlmsg(RTM_NEWROUTE, 0, 1, 1, &[0u8; 12]);
        // 把长度字段篡改成大于缓冲区
        m[0..4].copy_from_slice(&100_000u32.to_le_bytes());
        let err = parse_stream(RTM_NEWROUTE, 1, 1, &m).unwrap_err();
        assert!(matches!(err, Error::Netlink(_)));
        assert!(err.to_string().contains("长度非法"));
    }

    #[test]
    fn ownership_requires_all_four_conditions() {
        use crate::marks;
        let base = RuleEntry {
            family: Family::V4,
            priority: crate::system::route::RULE_PRIO_BASE,
            table: marks::table_of(1),
            action: FR_ACT_TO_TBL,
            fwmark: Some(1),
            fwmask: Some(marks::RULE_MASK),
            iifname: None,
            src: None,
            dst: None,
            protocol: Some(OUR_RTPROT),
            flags: 0,
        };
        assert!(base.is_ours());
        // 掩码不同：不是我们的
        let mut m1 = base.clone();
        m1.fwmask = Some(0xffffffff);
        assert!(!m1.is_ours());
        // 表号不匹配：不是我们的
        let mut m2 = base.clone();
        m2.table = 200;
        assert!(!m2.is_ours());
        // 优先级在保留区间外：不是我们的
        let mut m3 = base.clone();
        m3.priority = 32766;
        assert!(!m3.is_ours());
        // mark=0（未标记）
        let mut m4 = base.clone();
        m4.fwmark = Some(0);
        assert!(!m4.is_ours());
    }

    #[test]
    fn fake_netlink_replays_state() {
        let f = FakeNetlink::new();
        let spec = RuleSpec {
            family: Family::V4,
            priority: 1000,
            table: 100,
            fwmark: 1,
            fwmask: 0xff,
        };
        f.add_rule(&spec).unwrap();
        assert_eq!(f.dump_rules(Family::V4).unwrap().len(), 1);
        f.del_rule(&spec).unwrap();
        assert!(f.dump_rules(Family::V4).unwrap().is_empty());
        assert!(f.logged().iter().any(|l| l.starts_with("add_rule")));
    }

    #[test]
    fn ifindex_reads_sysfs_and_validates_name() {
        let dir = std::env::temp_dir().join(format!("smw-nl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("eth0")).unwrap();
        std::fs::write(dir.join("eth0/ifindex"), "3\n").unwrap();
        assert_eq!(ifindex("eth0", &dir).unwrap(), 3);
        assert!(matches!(
            ifindex("eth0/../evil", &dir),
            Err(Error::Validate(_))
        ));
        assert!(matches!(ifindex("", &dir), Err(Error::Validate(_))));
        assert!(ifindex("missing0", &dir).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ipv6_family_mapping() {
        assert_eq!(Family::V6.af(), AF_INET6);
        assert_eq!(Family::from_af(10), Some(Family::V6));
        assert_eq!(Family::from_af(17), None);
        assert_eq!(Family::V6.addr_len(), 16);
        assert_eq!(Ipv6Addr::LOCALHOST.to_string(), "::1");
    }
}
