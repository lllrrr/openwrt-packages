//! 线路/接口发现层：把 UCI 的 network/firewall 配置与内核里的真实设备状态对齐。
//!
//! 为什么需要这一层：用户在 `smartmwan` 里写的是**网口名或 netifd 接口名**
//! （`wan`、`wwan0`、`5g`），而策略路由需要的是设备名 + ifindex + 网关 + 源地址。
//! 5G 模块重拨后这四者都可能变，所以每次收敛前都要重新解析，
//! 并把「变化」作为事件上报（任务书第十二节的「5G 重拨导致网关变化」）。
//!
//! 数据来源全部是系统接口，不 fork 进程：
//! * `/etc/config/network`、`/etc/config/firewall` —— 用本项目的 UCI 解析器读；
//! * `/sys/class/net/<if>/...` —— 链路状态与计数器；
//! * netlink dump —— 默认路由、接口地址。

use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

use crate::config::schema::WanConfig;
use crate::config::uci::UciFile;
use crate::logging;
use crate::system::netlink::{AddrEntry, Family, RouteEntry, RouteOps, RTN_UNICAST, RT_TABLE_MAIN};
use crate::{Error, Result};

/// netifd 接口的一段信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetIface {
    /// UCI 段名，例如 `wan`、`wan_5g`。
    pub name: String,
    /// `option device` / `list device` / `option ifname` 声明的设备（可能是别名）。
    pub devices: Vec<String>,
    /// `option proto`，用于判断是不是动态拨号（pppoe/dhcp/ncm）。
    pub proto: String,
    /// `option delegate`，默认 true。
    pub delegate: bool,
    /// `option table` —— netifd 为该接口单独使用的路由表号（若有）。
    pub table: Option<u32>,
    /// `option ipaddr`/`option ip6addr` 静态地址（若有）。
    pub static_ip: Option<IpAddr>,
}

/// 防火墙 zone 的一段信息（本插件只需要成员与 masq 状态）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FirewallZone {
    pub name: String,
    pub networks: Vec<String>,
    /// zone 里直接写 `list device` 的写法（不经过 netifd 接口段）。
    pub devices: Vec<String>,
    pub masq: bool,
    /// `option masquerading`（旧字段名）或 `list direction/...` 形式的 nat 选项。
    pub nat: bool,
}

/// `/etc/config/network` + `/etc/config/firewall` 的合成视图。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Topology {
    pub interfaces: Vec<NetIface>,
    pub zones: Vec<FirewallZone>,
}

impl Topology {
    pub fn interface(&self, name: &str) -> Option<&NetIface> {
        self.interfaces.iter().find(|i| i.name == name)
    }

    pub fn zone(&self, name: &str) -> Option<&FirewallZone> {
        self.zones.iter().find(|z| z.name == name)
    }

    /// 某个 netifd 接口属于哪些 zone。
    pub fn zones_of(&self, iface: &str) -> Vec<&FirewallZone> {
        self.zones
            .iter()
            .filter(|z| z.networks.iter().any(|n| n == iface))
            .collect()
    }

    /// zone 里所有接口展开成设备名集合（用于 nft 的 `iifname` 集合）。
    pub fn zone_devices(&self, zone: &str) -> Vec<String> {
        let mut out = Vec::new();
        for z in self.zones.iter().filter(|z| z.name == zone) {
            for d in &z.devices {
                if !out.contains(d) {
                    out.push(d.clone());
                }
            }
            for n in &z.networks {
                match self.interface(n) {
                    Some(i) => {
                        for d in &i.devices {
                            if !out.contains(d) {
                                out.push(d.clone());
                            }
                        }
                        // 接口没有显式 device 时，netifd 默认用段名当设备名
                        if i.devices.is_empty() && !out.contains(n) {
                            out.push(n.clone());
                        }
                    }
                    None => {
                        if !out.contains(n) {
                            out.push(n.clone());
                        }
                    }
                }
            }
        }
        out
    }

    /// LAN 设备集合：所有 `lan_zones` 配置项展开后的并集。
    pub fn lan_devices(&self, lan_zones: &[String]) -> Vec<String> {
        let mut out = Vec::new();
        for z in lan_zones {
            for d in self.zone_devices(z) {
                if !out.contains(&d) {
                    out.push(d);
                }
            }
        }
        out
    }

    /// 检查每条启用线路是否在自己的 zone 里有 masq：
    /// 没有 masq 时，被我们改出口的流量会出现「源地址是私网、直接出 WAN」的
    /// 运营商侧丢弃问题，必须提示用户（任务书第八节 NAT/回程一致性）。
    pub fn check_wan_nat_coverage(&self, wans: &[WanConfig]) -> Vec<String> {
        let mut warn = Vec::new();
        for w in wans.iter().filter(|w| w.enabled) {
            let iface = self.interface(&w.name);
            let zones = match iface {
                Some(_) => self.zones_of(&w.name),
                None => Vec::new(),
            };
            if zones.is_empty() {
                warn.push(format!(
                    "线路 {}（netifd 接口 {}）不属于任何 firewall zone，无法确认是否做了 masq",
                    w.name, w.name
                ));
                continue;
            }
            if !zones.iter().any(|z| z.masq || z.nat) {
                warn.push(format!(
                    "线路 {} 所在的 zone（{}）没有开启 masq/NAT；换出口后源地址不会被重写，运营商会丢弃该流量",
                    w.name,
                    zones.iter().map(|z| z.name.as_str()).collect::<Vec<_>>().join(",")
                ));
            }
        }
        warn
    }
}

/// 解析 `/etc/config/network`。
pub fn parse_network(text: &str) -> Result<Topology> {
    let (file, warnings) = UciFile::parse_report(text)?;
    // 非致命告警（可解析但不规范的行）必须留痕，否则用户永远不知道自己写的配置有歧义。
    for w in warnings {
        logging::warn_ctx("interface", "parse-network", &w, &[]);
    }
    Ok(topology_from(&file))
}

/// 解析 `/etc/config/firewall` 并合并进已有的 network 视图。
pub fn merge_firewall(topo: &mut Topology, text: &str) -> Result<()> {
    let (file, warnings) = UciFile::parse_report(text)?;
    for w in warnings {
        logging::warn_ctx("interface", "parse-firewall", &w, &[]);
    }
    for s in file.sections_of("zone") {
        let mut networks = s.list("network");
        networks.sort();
        networks.dedup();
        let devices = s.list("device");
        // fw4 的写法是匿名段 + `option name`；`config zone 'lan'` 的写法也要支持。
        let zname = s
            .name
            .clone()
            .filter(|n| !n.is_empty())
            .or_else(|| s.option("name"))
            .unwrap_or_default();
        let masq = truthy(s.option("masq").as_deref().unwrap_or(""))
            || truthy(s.option("masquerade").as_deref().unwrap_or(""));
        let nat = truthy(s.option("nat").as_deref().unwrap_or(""));
        topo.zones.push(FirewallZone {
            name: zname,
            networks,
            devices,
            masq,
            // fw4 里 `option masq '1'` 就够；`nat` 只在没有 masq 时作为提示依据。
            nat,
        });
    }
    Ok(())
}

fn topology_from(file: &UciFile) -> Topology {
    let mut topo = Topology::default();
    for s in file.sections_of("interface") {
        let mut devices: Vec<String> = Vec::new();
        for d in s.list("device") {
            if !devices.contains(&d) {
                devices.push(d);
            }
        }
        if let Some(d) = s.option("device") {
            // `option device` 可以是空格分隔的多设备（bond/bridge 写法）
            for part in d.split_whitespace() {
                if !part.is_empty() && !devices.contains(&part.to_string()) {
                    devices.push(part.to_string());
                }
            }
        }
        if let Some(i) = s.option("ifname") {
            for part in i.split_whitespace() {
                if !part.is_empty() && !devices.contains(&part.to_string()) {
                    devices.push(part.to_string());
                }
            }
        }
        let static_ip = s
            .option("ipaddr")
            .and_then(|v| v.split('/').next().unwrap_or("").parse::<IpAddr>().ok())
            .or_else(|| {
                s.option("ip6addr")
                    .and_then(|v| v.split('/').next().unwrap_or("").parse::<IpAddr>().ok())
            });
        topo.interfaces.push(NetIface {
            name: s.name.clone().unwrap_or_default(),
            devices,
            proto: s.option("proto").unwrap_or_default(),
            delegate: !matches!(
                s.option("delegate").as_deref(),
                Some("0") | Some("off") | Some("no")
            ),
            table: s.option("table").and_then(|v| v.parse::<u32>().ok()),
            static_ip,
        });
    }
    topo
}

/// 空字符串 = 未配置（不是非法值）；非法内容同样按未配置处理，由校验层负责报错。
fn parse_ip_opt(s: &str) -> Option<IpAddr> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    s.parse::<IpAddr>().ok()
}

fn truthy(v: &str) -> bool {
    matches!(v, "1" | "on" | "yes" | "true" | "enabled")
}

/// `/sys/class/net/<if>/` 下一个设备的观测值。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DeviceState {
    pub name: String,
    pub exists: bool,
    /// `operstate`：up / down / unknown（很多桥/虚接口一直是 unknown，不能当故障）。
    pub operstate: String,
    /// `carrier`：1 有载波。文件不存在（虚接口）时为 None，此时以 operstate 判断。
    pub carrier: Option<bool>,
    pub ifindex: Option<u32>,
    pub mtu: Option<u32>,
    pub mac: Option<String>,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_packets: u64,
    pub tx_packets: u64,
    pub rx_errors: u64,
    pub tx_errors: u64,
    pub rx_dropped: u64,
    pub tx_dropped: u64,
}

impl DeviceState {
    /// 链路是否可用。carrier 优先，其次 operstate；
    /// 两者都没有信息时保守认为可用（虚接口常见），由探测结果决定健康度。
    pub fn link_up(&self) -> bool {
        if !self.exists {
            return false;
        }
        if let Some(c) = self.carrier {
            return c;
        }
        match self.operstate.as_str() {
            "up" => true,
            "down" | "lowerlayerdown" | "dormant" | "notpresent" => false,
            _ => true,
        }
    }
}

/// sysfs 读取器；`root` 可注入以便用 fixture 目录做单元测试。
#[derive(Debug, Clone)]
pub struct SysFs {
    pub root: PathBuf,
}

impl Default for SysFs {
    fn default() -> SysFs {
        SysFs {
            root: PathBuf::from("/sys/class/net"),
        }
    }
}

impl SysFs {
    pub fn new(root: impl AsRef<Path>) -> SysFs {
        SysFs {
            root: root.as_ref().to_path_buf(),
        }
    }

    /// 读取一个设备；设备不存在返回 `exists = false` 的骨架而不是错误
    /// （用户配了还没插上的 WAN 是常态，UI 要能显示「设备不存在」）。
    pub fn device(&self, name: &str) -> DeviceState {
        let mut d = DeviceState {
            name: name.to_string(),
            ..Default::default()
        };
        if name.is_empty() || name.contains('/') || name.contains('\0') || name.len() > 15 {
            return d;
        }
        let base = self.root.join(name);
        if !base.exists() {
            return d;
        }
        d.exists = true;
        d.operstate = read_trim(&base.join("operstate")).unwrap_or_default();
        d.carrier = read_trim(&base.join("carrier")).map(|v| v == "1");
        d.ifindex = read_trim(&base.join("ifindex")).and_then(|v| v.parse().ok());
        d.mtu = read_trim(&base.join("mtu")).and_then(|v| v.parse().ok());
        d.mac = read_trim(&base.join("address")).filter(|m| m != "00:00:00:00:00:00");
        let st = base.join("statistics");
        d.rx_bytes = read_u64(&st.join("rx_bytes"));
        d.tx_bytes = read_u64(&st.join("tx_bytes"));
        d.rx_packets = read_u64(&st.join("rx_packets"));
        d.tx_packets = read_u64(&st.join("tx_packets"));
        d.rx_errors = read_u64(&st.join("rx_errors"));
        d.tx_errors = read_u64(&st.join("tx_errors"));
        d.rx_dropped = read_u64(&st.join("rx_dropped"));
        d.tx_dropped = read_u64(&st.join("tx_dropped"));
        d
    }

    /// 列出所有设备名。
    pub fn list(&self) -> Vec<String> {
        let mut out = Vec::new();
        if let Ok(rd) = std::fs::read_dir(&self.root) {
            for e in rd.flatten() {
                if let Some(n) = e.file_name().to_str() {
                    out.push(n.to_string());
                }
            }
        }
        out.sort();
        out
    }
}

fn read_trim(p: &Path) -> Option<String> {
    std::fs::read_to_string(p)
        .ok()
        .map(|s| s.trim().to_string())
}

fn read_u64(p: &Path) -> u64 {
    read_trim(p).and_then(|v| v.parse().ok()).unwrap_or(0)
}

/// 从 netlink 路由里找某个设备上的默认路由网关。
///
/// 返回 `(网关, 是否只有链路级默认路由)`：
/// `default dev wwan0 scope link`（无网关）在点对点链路上是合法的，
/// 这时策略路由表里也要装同样形式的默认路由，而不是硬造一个网关。
pub fn default_gateway(
    routes: &[RouteEntry],
    ifindex: u32,
    family: Family,
) -> (Option<IpAddr>, bool) {
    let mut best: Option<&RouteEntry> = None;
    for r in routes.iter().filter(|r| {
        r.family == family
            && r.table == RT_TABLE_MAIN as u32
            && r.is_default()
            && r.oif == Some(ifindex)
    }) {
        best = match best {
            Some(cur) if cur.priority <= r.priority => Some(cur),
            _ => Some(r),
        };
    }
    match best {
        Some(r) => (r.gateway, r.gateway.is_none()),
        None => (None, false),
    }
}

/// 判断某地址族在 main 表里是否存在默认路由（用于 UI 的「系统本身是否已上网」提示）。
pub fn has_main_default(routes: &[RouteEntry], family: Family) -> bool {
    routes.iter().any(|r| {
        r.family == family
            && r.table == RT_TABLE_MAIN as u32
            && r.is_default()
            && r.kind == RTN_UNICAST
    })
}

/// 为线路挑选源地址：配置优先，其次该设备上第一个「非弃用、非 tentative」的同族地址。
pub fn pick_source(
    addrs: &[AddrEntry],
    ifindex: u32,
    family: Family,
    configured: Option<IpAddr>,
) -> Option<IpAddr> {
    if let Some(c) = configured {
        return Some(c);
    }
    let mut cand = addrs
        .iter()
        .filter(|a| a.ifindex == ifindex && a.family == family && !a.deprecated && !a.tentative);
    // IPv6 隐私扩展的临时地址带 IFA_F_SECONDARY，会随时间轮换；
    // 用它做 prefsrc 会让路由每隔一段时间对不上，所以优先取持久地址。
    let mut next_persistent = cand.clone().find(|a| !a.secondary);
    let chosen = next_persistent.take().or_else(|| cand.next());
    chosen.map(|a| a.address)
}

/// 一次解析得到的内核侧目标（交给 `route::plan`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub wan: String,
    pub device: String,
    pub ifindex: u32,
    pub link_up: bool,
    pub gw4: Option<IpAddr>,
    pub gw6: Option<IpAddr>,
    pub src4: Option<IpAddr>,
    pub src6: Option<IpAddr>,
    /// 点对点链路：允许安装「无网关的链路级默认路由」。
    pub link_default: bool,
    /// 解析过程中的告警（设备不存在、没有默认路由等），必须显示给用户。
    pub notes: Vec<String>,
}

/// 把一条 `WanConfig` 解析成 [`Resolved`]。
pub fn resolve_wan(
    w: &WanConfig,
    topo: &Topology,
    routes: &[RouteEntry],
    addrs: &[AddrEntry],
    sysfs: &SysFs,
    enable_ipv6: bool,
) -> Result<Resolved> {
    // 设备解析顺序：配置里显式 device > netifd 接口段的 device/ifname > 段名本身
    let iface = topo.interface(&w.name);
    let mut devices: Vec<String> = Vec::new();
    if !w.device.is_empty() {
        devices.push(w.device.clone());
    }
    if let Some(i) = iface {
        for d in &i.devices {
            if !devices.contains(d) {
                devices.push(d.clone());
            }
        }
    }
    if devices.is_empty() {
        devices.push(w.name.clone());
    }

    let mut notes = Vec::new();
    let mut chosen: Option<(String, u32, DeviceState)> = None;
    for d in &devices {
        let st = sysfs.device(d);
        if st.exists {
            if let Some(idx) = st.ifindex {
                chosen = Some((d.clone(), idx, st));
                break;
            }
            notes.push(format!("设备 {d} 存在但读不到 ifindex"));
        } else {
            notes.push(format!("设备 {d} 不存在"));
        }
    }
    let Some((device, ifindex, state)) = chosen else {
        notes.push(format!(
            "线路 {} 的候选设备全部不可用: {}",
            w.name,
            devices.join(",")
        ));
        return Err(Error::NoRoute {
            wan: w.name.clone(),
            reason: notes.join("; "),
        });
    };
    if !state.link_up() {
        notes.push(format!(
            "设备 {device} 链路未 up（operstate={}）",
            state.operstate
        ));
    }
    if iface.is_none() && w.device.is_empty() {
        notes.push(format!(
            "/etc/config/network 中没有名为 {} 的接口段",
            w.name
        ));
    }

    let (gw4, link_only4) = default_gateway(routes, ifindex, Family::V4);
    if gw4.is_none() && !link_only4 {
        notes.push(format!(
            "main 表里没有走 {device} 的默认路由（可能未拨号或未 delegate）"
        ));
    }
    let (gw6, link_only6) = if enable_ipv6 {
        default_gateway(routes, ifindex, Family::V6)
    } else {
        (None, false)
    };

    // 用户显式配置优先于自动发现：静态 WAN（光纤猫旁挂、专线）常需要手写网关/源地址。
    let cfg_gw = parse_ip_opt(&w.gateway);
    let cfg_src = parse_ip_opt(&w.src_ip);
    let gw4 = gw4.or_else(|| cfg_gw.filter(|a| matches!(a, IpAddr::V4(_))));
    let gw6 = if enable_ipv6 {
        gw6.or_else(|| cfg_gw.filter(|a| matches!(a, IpAddr::V6(_))))
    } else {
        None
    };
    let src4 = pick_source(
        addrs,
        ifindex,
        Family::V4,
        cfg_src.filter(|a| matches!(a, IpAddr::V4(_))),
    );
    let src6 = if enable_ipv6 {
        pick_source(
            addrs,
            ifindex,
            Family::V6,
            cfg_src.filter(|a| matches!(a, IpAddr::V6(_))),
        )
    } else {
        None
    };

    Ok(Resolved {
        wan: w.name.clone(),
        device,
        ifindex,
        link_up: state.link_up(),
        gw4,
        gw6,
        src4,
        src6,
        link_default: link_only4 || link_only6,
        notes,
    })
}

impl Resolved {
    /// 转成策略路由的目标；`slot` 由上层按配置顺序分配（1..=MAX_WANS）。
    pub fn to_target(&self, slot: u8) -> crate::system::route::WanTarget {
        crate::system::route::WanTarget {
            name: self.wan.clone(),
            slot,
            device: self.device.clone(),
            ifindex: self.ifindex,
            gw4: self.gw4,
            src4: self.src4,
            gw6: self.gw6,
            src6: self.src6,
            link_default: self.link_default,
        }
    }
}

/// 两次设备状态之间的关键变化（网关/地址/链路），用于事件流。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceChange {
    LinkDown {
        device: String,
    },
    LinkUp {
        device: String,
    },
    /// 5G 模块重拨：网关或本机地址变了，必须重建该线路的表内容并重新探测。
    GatewayChanged {
        device: String,
        old: Option<IpAddr>,
        new: Option<IpAddr>,
    },
    DeviceGone {
        device: String,
    },
    DeviceAppeared {
        device: String,
    },
    /// netifd 接口段换了设备（例如把 `device` 从 eth1 改成 eth2）。
    DeviceRenamed {
        old: String,
        new: String,
    },
}

/// 比较两次的 [`Resolved`] 快照。
pub fn diff_resolved(
    prev: &HashMap<String, Resolved>,
    cur: &HashMap<String, Resolved>,
) -> Vec<DeviceChange> {
    let mut out = Vec::new();
    for (name, p) in prev {
        let Some(c) = cur.get(name) else {
            out.push(DeviceChange::DeviceGone {
                device: p.device.clone(),
            });
            continue;
        };
        if p.link_up && !c.link_up {
            out.push(DeviceChange::LinkDown {
                device: c.device.clone(),
            });
        }
        if !p.link_up && c.link_up {
            out.push(DeviceChange::LinkUp {
                device: c.device.clone(),
            });
        }
        if p.gw4 != c.gw4 || p.src4 != c.src4 {
            out.push(DeviceChange::GatewayChanged {
                device: c.device.clone(),
                old: p.gw4.or(p.src4),
                new: c.gw4.or(c.src4),
            });
        }
        if p.device != c.device {
            out.push(DeviceChange::DeviceRenamed {
                old: p.device.clone(),
                new: c.device.clone(),
            });
        }
    }
    for (name, c) in cur {
        if !prev.contains_key(name) {
            out.push(DeviceChange::DeviceAppeared {
                device: format!("{name}→{}", c.device),
            });
        }
    }
    out.sort_by(|a, b| format!("{a:?}").cmp(&format!("{b:?}")));
    out
}

/// 一次性把所有线路解析完；失败不阻断其它线路（每条线路的失败变成 notes/错误列表）。
pub fn resolve_all(
    wans: &[WanConfig],
    topo: &Topology,
    ops: &dyn RouteOps,
    sysfs: &SysFs,
    enable_ipv6: bool,
) -> (HashMap<String, Resolved>, Vec<(String, String)>) {
    let mut routes: Vec<RouteEntry> = Vec::new();
    for f in [Family::V4, Family::V6] {
        match ops.dump_routes(f, RT_TABLE_MAIN as u32) {
            Ok(v) => routes.extend(v),
            Err(e) => {
                crate::logging::warn_ctx(
                    "interface",
                    "dump-routes",
                    &format!("{f:?} 路由 dump 失败: {e}"),
                    &[],
                );
            }
        }
    }
    let mut addrs: Vec<AddrEntry> = Vec::new();
    for f in [Family::V4, Family::V6] {
        match ops.dump_addresses(f) {
            Ok(v) => addrs.extend(v),
            Err(e) => {
                crate::logging::warn_ctx(
                    "interface",
                    "dump-addr",
                    &format!("{f:?} 地址 dump 失败: {e}"),
                    &[],
                );
            }
        }
    }
    let mut ok = HashMap::new();
    let mut errs = Vec::new();
    for w in wans {
        match resolve_wan(w, topo, &routes, &addrs, sysfs, enable_ipv6) {
            Ok(r) => {
                ok.insert(w.name.clone(), r);
            }
            Err(e) => errs.push((w.name.clone(), e.to_string())),
        }
    }
    (ok, errs)
}

/// 计数器快照，供流量统计与速率计算。
#[derive(Debug, Clone, Default)]
pub struct TrafficSample {
    pub at_ms: u64,
    pub per_device: HashMap<String, (u64, u64)>,
}

impl TrafficSample {
    /// 与上一次采样求差；设备计数器回绕（重拨/重建接口）时返回 0 而不是负数下溢。
    pub fn delta(&self, prev: &TrafficSample) -> HashMap<String, (u64, u64)> {
        let mut out = HashMap::new();
        for (k, (rx, tx)) in &self.per_device {
            let (prx, ptx) = prev.per_device.get(k).copied().unwrap_or((0, 0));
            let drx = rx.saturating_sub(prx);
            let dtx = tx.saturating_sub(ptx);
            out.insert(k.clone(), (drx, dtx));
        }
        out
    }

    pub fn elapsed_ms(&self, prev: &TrafficSample) -> u64 {
        self.at_ms.saturating_sub(prev.at_ms)
    }
}

/// 采样所有涉及的设备的累计字节数。
pub fn sample_traffic(sysfs: &SysFs, devices: &[String], at_ms: u64) -> TrafficSample {
    let mut per_device = HashMap::new();
    for d in devices {
        let st = sysfs.device(d);
        per_device.insert(d.clone(), (st.rx_bytes, st.tx_bytes));
    }
    TrafficSample { at_ms, per_device }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::WanConfig;
    use crate::system::netlink::FakeNetlink;
    use std::net::Ipv4Addr;

    fn fixture_sysfs(tag: &str) -> SysFs {
        let root = std::env::temp_dir().join(format!("smw-sys-{}-{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for (name, ifindex, carrier, operstate) in [
            ("eth1", "4", "1", "up"),
            ("wwan0", "7", "1", "up"),
            ("br-lan", "6", "1", "up"),
        ] {
            let d = root.join(name);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("ifindex"), format!("{ifindex}\n")).unwrap();
            std::fs::write(d.join("carrier"), format!("{carrier}\n")).unwrap();
            std::fs::write(d.join("operstate"), format!("{operstate}\n")).unwrap();
            std::fs::write(d.join("mtu"), "1500\n").unwrap();
            std::fs::write(d.join("address"), "aa:bb:cc:dd:ee:ff\n").unwrap();
            let st = d.join("statistics");
            std::fs::create_dir_all(&st).unwrap();
            std::fs::write(st.join("rx_bytes"), "1000\n").unwrap();
            std::fs::write(st.join("tx_bytes"), "2000\n").unwrap();
            std::fs::write(st.join("rx_packets"), "10\n").unwrap();
            std::fs::write(st.join("tx_packets"), "20\n").unwrap();
            std::fs::write(st.join("rx_errors"), "0\n").unwrap();
            std::fs::write(st.join("tx_errors"), "0\n").unwrap();
            std::fs::write(st.join("rx_dropped"), "1\n").unwrap();
            std::fs::write(st.join("tx_dropped"), "0\n").unwrap();
        }
        SysFs::new(&root)
    }

    fn cleanup(s: &SysFs) {
        let _ = std::fs::remove_dir_all(&s.root);
    }

    const NETWORK: &str = r#"
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fd12:3456:789a::/48'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports 'eth0'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.1.1'

config interface 'wan'
    option device 'eth1'
    option proto 'dhcp'

config interface 'wan_5g'
    option device 'wwan0'
    option proto 'dhcp'
    option delegate '0'
"#;

    const FIREWALL: &str = r#"
config zone
    option name 'lan'
    list network 'lan'
    option input 'ACCEPT'
    option forward 'ACCEPT'
    option output 'ACCEPT'
    list device 'br-lan'

config zone
    option name 'wan'
    list network 'wan'
    list network 'wan_5g'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '1'
    option mtu_fix '1'
"#;

    fn topo() -> Topology {
        let mut t = parse_network(NETWORK).unwrap();
        merge_firewall(&mut t, FIREWALL).unwrap();
        t
    }

    #[test]
    fn parses_interfaces_and_zones() {
        let t = topo();
        assert_eq!(t.interfaces.len(), 4);
        let wan = t.interface("wan").unwrap();
        assert_eq!(wan.devices, vec!["eth1".to_string()]);
        assert_eq!(wan.proto, "dhcp");
        let g5 = t.interface("wan_5g").unwrap();
        assert!(!g5.delegate, "delegate '0' 要被识别");
        assert!(t.zone("wan").unwrap().masq);
        assert_eq!(t.zone("lan").unwrap().networks, vec!["lan".to_string()]);
    }

    #[test]
    fn lan_devices_expands_zone_membership() {
        let t = topo();
        // zone 里 `list network 'lan'` 展开成 br-lan，`list device 'br-lan'` 重复项要被去掉
        assert_eq!(
            t.lan_devices(&["lan".to_string()]),
            vec!["br-lan".to_string()]
        );
        // 未知 zone 返回空，调用方要据此报「LAN 区域未匹配到设备」
        assert!(t.lan_devices(&["nope".to_string()]).is_empty());
    }

    #[test]
    fn nat_coverage_warns_for_missing_masq() {
        let mut t = topo();
        let wans = vec![
            WanConfig {
                name: "wan".into(),
                enabled: true,
                ..Default::default()
            },
            WanConfig {
                name: "wan_5g".into(),
                enabled: true,
                ..Default::default()
            },
        ];
        assert!(
            t.check_wan_nat_coverage(&wans).is_empty(),
            "wan zone 有 masq"
        );
        // 停用 masq 后必须报警
        t.zones.iter_mut().for_each(|z| z.masq = false);
        let warns = t.check_wan_nat_coverage(&wans);
        assert_eq!(warns.len(), 2);
        assert!(warns[0].contains("masq"));
    }

    #[test]
    fn nat_coverage_warns_for_unknown_interface() {
        let t = topo();
        let wans = vec![WanConfig {
            name: "ghost".into(),
            enabled: true,
            ..Default::default()
        }];
        let warns = t.check_wan_nat_coverage(&wans);
        assert_eq!(warns.len(), 1);
        assert!(warns[0].contains("不属于任何"));
        // 禁用的线路不检查
        let wans2 = vec![WanConfig {
            name: "ghost".into(),
            enabled: false,
            ..Default::default()
        }];
        assert!(t.check_wan_nat_coverage(&wans2).is_empty());
    }

    #[test]
    fn sysfs_reads_state_and_handles_missing_device() {
        let s = fixture_sysfs("read");
        let d = s.device("eth1");
        assert!(d.exists);
        assert_eq!(d.ifindex, Some(4));
        assert_eq!(d.carrier, Some(true));
        assert!(d.link_up());
        assert_eq!(d.rx_bytes, 1000);
        assert_eq!(d.tx_bytes, 2000);
        assert_eq!(d.mtu, Some(1500));
        assert_eq!(d.mac.as_deref(), Some("aa:bb:cc:dd:ee:ff"));
        let missing = s.device("nope0");
        assert!(!missing.exists);
        assert!(!missing.link_up());
        // 路径穿越式名字不能逃逸到别的目录
        let evil = s.device("../../etc");
        assert!(!evil.exists);
        cleanup(&s);
    }

    #[test]
    fn carrier_false_overrides_operstate_up() {
        let root = std::env::temp_dir().join(format!("smw-sys-carrier-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("eth9")).unwrap();
        std::fs::write(root.join("eth9/ifindex"), "9\n").unwrap();
        std::fs::write(root.join("eth9/carrier"), "0\n").unwrap();
        std::fs::write(root.join("eth9/operstate"), "up\n").unwrap();
        let s = SysFs::new(&root);
        let d = s.device("eth9");
        assert_eq!(d.carrier, Some(false));
        assert!(!d.link_up(), "carrier=0 必须判为 down，即使 operstate=up");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn virtual_device_without_carrier_uses_operstate() {
        let root = std::env::temp_dir().join(format!("smw-sys-virt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("ipsec0")).unwrap();
        std::fs::write(root.join("ipsec0/ifindex"), "12\n").unwrap();
        std::fs::write(root.join("ipsec0/operstate"), "unknown\n").unwrap();
        let d = SysFs::new(&root).device("ipsec0");
        assert_eq!(d.carrier, None);
        assert!(
            d.link_up(),
            "虚接口没有 carrier 文件时保守认为可用，由探测决定健康度"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    fn route_v4(
        table: u32,
        dst: Option<&str>,
        len: u8,
        gw: Option<&str>,
        oif: u32,
        kind: u8,
        prio: u32,
    ) -> RouteEntry {
        RouteEntry {
            family: Family::V4,
            table,
            dst_len: len,
            dst: dst.map(|d| d.parse().unwrap()),
            gateway: gw.map(|g| g.parse().unwrap()),
            oif: Some(oif),
            prefsrc: None,
            priority: prio,
            protocol: 2,
            scope: 253,
            kind,
        }
    }

    #[test]
    fn default_gateway_picks_lowest_metric_and_detects_link_only() {
        let routes = vec![
            route_v4(254, None, 0, Some("10.0.0.1"), 4, RTN_UNICAST, 100),
            route_v4(254, None, 0, Some("10.0.0.2"), 4, RTN_UNICAST, 50),
            route_v4(254, Some("10.0.0.0"), 24, None, 4, RTN_UNICAST, 0),
        ];
        assert_eq!(
            default_gateway(&routes, 4, Family::V4).0,
            Some(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)))
        );
        // 点对点：default dev wwan0 scope link（没有 RTA_GATEWAY）
        let p2p = vec![route_v4(254, None, 0, None, 7, RTN_UNICAST, 0)];
        let (gw, link_only) = default_gateway(&p2p, 7, Family::V4);
        assert_eq!(gw, None);
        assert!(
            link_only,
            "无网关的链路级默认路由要被识别，不能当成「没有出口」"
        );
        // 别的设备不算
        assert_eq!(default_gateway(&routes, 7, Family::V4).0, None);
        assert!(has_main_default(&routes, Family::V4));
        assert!(!has_main_default(&routes, Family::V6));
    }

    #[test]
    fn source_selection_prefers_config_then_usable_address() {
        let addrs = vec![
            AddrEntry {
                family: Family::V4,
                prefix_len: 24,
                ifindex: 4,
                address: "10.0.0.55".parse().unwrap(),
                label: Some("eth1".into()),
                permanent: false,
                secondary: false,
                deprecated: true,
                tentative: false,
            },
            AddrEntry {
                family: Family::V4,
                prefix_len: 24,
                ifindex: 4,
                address: "10.0.0.56".parse().unwrap(),
                label: Some("eth1".into()),
                permanent: true,
                secondary: false,
                deprecated: false,
                tentative: false,
            },
        ];
        assert_eq!(
            pick_source(&addrs, 4, Family::V4, None),
            Some("10.0.0.56".parse().unwrap())
        );
        assert_eq!(
            pick_source(&addrs, 4, Family::V4, Some("1.2.3.4".parse().unwrap())),
            Some("1.2.3.4".parse().unwrap())
        );
        assert_eq!(pick_source(&addrs, 9, Family::V4, None), None);
    }

    fn wan(name: &str, device: &str) -> WanConfig {
        WanConfig {
            name: name.into(),
            enabled: true,
            device: device.into(),
            ..Default::default()
        }
    }

    #[test]
    fn resolve_wan_combines_config_sysfs_and_netlink() {
        let s = fixture_sysfs("resolve");
        let t = topo();
        let routes = vec![route_v4(
            254,
            None,
            0,
            Some("192.168.100.1"),
            4,
            RTN_UNICAST,
            0,
        )];
        let addrs = vec![AddrEntry {
            family: Family::V4,
            prefix_len: 24,
            ifindex: 4,
            address: "192.168.100.20".parse().unwrap(),
            label: None,
            permanent: true,
            secondary: false,
            deprecated: false,
            tentative: false,
        }];
        let r = resolve_wan(&wan("wan", ""), &t, &routes, &addrs, &s, false).unwrap();
        assert_eq!(r.device, "eth1");
        assert_eq!(r.ifindex, 4);
        assert_eq!(r.gw4, Some("192.168.100.1".parse().unwrap()));
        assert_eq!(r.src4, Some("192.168.100.20".parse().unwrap()));
        assert!(r.link_up);
        assert!(r.notes.is_empty(), "不该有告警：{:?}", r.notes);
        cleanup(&s);
    }

    #[test]
    fn resolve_wan_reports_missing_default_route_but_still_resolves() {
        let s = fixture_sysfs("nogw");
        let t = topo();
        let r = resolve_wan(&wan("wan", ""), &t, &[], &[], &s, false).unwrap();
        assert_eq!(r.gw4, None);
        assert!(r.notes.iter().any(|n| n.contains("默认路由")));
        cleanup(&s);
    }

    #[test]
    fn resolve_wan_fails_when_device_absent() {
        let s = fixture_sysfs("absent");
        let t = topo();
        let e = resolve_wan(&wan("ghost", "nope0"), &t, &[], &[], &s, false).unwrap_err();
        assert!(matches!(e, Error::NoRoute { .. }));
        assert!(e.to_string().contains("nope0"));
        cleanup(&s);
    }

    #[test]
    fn resolve_all_isolates_failures_per_wan() {
        let s = fixture_sysfs("all");
        let t = topo();
        let fake = FakeNetlink::default();
        let (ok, errs) = resolve_all(
            &[wan("wan", ""), wan("wan_5g", ""), wan("ghost", "nope")],
            &t,
            &fake,
            &s,
            false,
        );
        assert_eq!(ok.len(), 2);
        assert_eq!(errs.len(), 1);
        assert_eq!(errs[0].0, "ghost");
        cleanup(&s);
    }

    #[test]
    fn gateway_change_diff_detects_redial() {
        let mut prev = HashMap::new();
        prev.insert(
            "wan_5g".into(),
            Resolved {
                wan: "wan_5g".into(),
                device: "wwan0".into(),
                ifindex: 7,
                link_up: true,
                gw4: Some("10.10.10.1".parse().unwrap()),
                gw6: None,
                src4: Some("10.10.10.5".parse().unwrap()),
                src6: None,
                link_default: false,
                notes: vec![],
            },
        );
        let mut cur = HashMap::new();
        cur.insert(
            "wan_5g".into(),
            Resolved {
                gw4: Some("10.20.20.1".parse().unwrap()),
                src4: Some("10.20.20.9".parse().unwrap()),
                ..prev["wan_5g"].clone()
            },
        );
        let ch = diff_resolved(&prev, &cur);
        assert!(
            matches!(ch[0], DeviceChange::GatewayChanged { .. }),
            "{:?}",
            ch
        );
        // 链路断开
        let mut down = cur.clone();
        down.get_mut("wan_5g").unwrap().link_up = false;
        let ch2 = diff_resolved(&cur, &down);
        assert!(ch2
            .iter()
            .any(|c| matches!(c, DeviceChange::LinkDown { .. })));
        // 线路被删
        let ch3 = diff_resolved(&prev, &HashMap::new());
        assert!(ch3
            .iter()
            .any(|c| matches!(c, DeviceChange::DeviceGone { .. })));
    }

    #[test]
    fn traffic_delta_saturates_on_counter_wrap() {
        let prev = TrafficSample {
            at_ms: 1000,
            per_device: [("eth1".to_string(), (1000, 2000))].into_iter().collect(),
        };
        let cur = TrafficSample {
            at_ms: 3000,
            per_device: [
                ("eth1".to_string(), (1500, 100)),
                ("eth9".to_string(), (10, 10)),
            ]
            .into_iter()
            .collect(),
        };
        let d = cur.delta(&prev);
        assert_eq!(d["eth1"], (500, 0), "计数器回绕不能让差值下溢");
        assert_eq!(d["eth9"], (10, 10), "新设备按 0 基线处理");
        assert_eq!(cur.elapsed_ms(&prev), 2000);
    }

    #[test]
    fn sample_traffic_reads_every_listed_device() {
        let s = fixture_sysfs("sample");
        let t = sample_traffic(&s, &["eth1".to_string(), "ghost0".to_string()], 123);
        assert_eq!(t.at_ms, 123);
        assert_eq!(t.per_device.get("eth1"), Some(&(1000u64, 2000u64)));
        assert_eq!(t.per_device.get("ghost0"), Some(&(0u64, 0u64)));
        cleanup(&s);
    }

    #[test]
    fn unknown_proto_and_static_ip_are_parsed() {
        let t = parse_network("config interface 'sta'\n    option proto 'static'\n    option ipaddr '192.168.9.9/24'\n    option device 'wlan0'\n    option table '200'\n").unwrap();
        let i = t.interface("sta").unwrap();
        assert_eq!(i.static_ip, Some("192.168.9.9".parse().unwrap()));
        assert_eq!(i.table, Some(200));
        // 非法 ipaddr 不能让解析失败，只是没有静态地址
        let t2 = parse_network("config interface 'x'\n    option ipaddr 'not-an-ip'\n").unwrap();
        assert_eq!(t2.interface("x").unwrap().static_ip, None);
    }
}
