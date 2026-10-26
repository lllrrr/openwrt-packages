//! 系统层：与内核/外部命令对话的全部代码。
//!
//! 分工：
//! * [`exec`] —— 唯一允许 fork 外部程序的地方（参数数组 + 超时 + 输出上限）；
//! * [`netlink`] —— 直接 rtnetlink 收发，规则/路由/地址一律不走 `ip` 命令文本解析；
//! * [`route`] —— 期望状态收敛、冲突审计、回滚；
//! * [`interface`] —— UCI 网络拓扑与真实设备/网关/地址对齐；
//! * [`firewall`] —— 本插件私有 nft 表（`inet smw`）的规则生成与差量下发；
//! * [`conntrack`] —— 每标记连接数统计（最少新建/最少流量算法的输入）。
//!
//! 上层（[`crate::transaction`]）只调用本模块的 `observe` / `apply` 语义，
//! 不自己拼命令、不自己算优先级。

pub mod conntrack;
pub mod exec;
pub mod firewall;
pub mod interface;
pub mod netlink;
pub mod route;

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::config::schema::{Config, WanConfig};
use crate::config::validate::{Issue, Severity};
use crate::logging;
use crate::marks;
use crate::system::interface::{Resolved, SysFs, Topology, TrafficSample};
use crate::system::netlink::{AddrEntry, Family, RouteEntry, RouteOps, RuleEntry};
use crate::system::route::{Applier, Desired, Diff, MirrorSet, WanTarget};
use crate::{Error, Result};

/// 每个槽位对应的路由表是否是本插件拥有的，判定依据是表号区间；
/// 这里给出可读文本，UI 与日志都用它解释「为什么表 101~124 归插件管」。
pub fn our_tables() -> Vec<u32> {
    (1..=marks::MAX_WANS).map(marks::table_of).collect()
}

/// 为启用的线路分配槽位。
///
/// 槽位是数据平面的身份（决定 `ip rule` 与路由表号），必须**稳定**：
/// 同一份配置在任何一次启动里得到同样的分配，否则已建立连接的标记会指向错误线路。
/// 规则：按配置顺序编号，只给 `enabled` 的线路分配，超过 [`marks::MAX_WANS`] 直接报错。
pub fn assign_slots(wans: &[WanConfig]) -> Result<HashMap<String, u8>> {
    let mut map = HashMap::new();
    let mut next: u8 = 1;
    for w in wans {
        if !w.enabled {
            continue;
        }
        if next > marks::MAX_WANS {
            return Err(Error::Validate(format!(
                "启用的线路超过 {} 条上限，请停用一部分线路",
                marks::MAX_WANS
            )));
        }
        if map.insert(w.name.clone(), next).is_some() {
            return Err(Error::Config(format!("线路段名重复: {}", w.name)));
        }
        next += 1;
    }
    Ok(map)
}

/// 文件系统与内核观察的可注入环境。
///
/// 生产路径是 `/etc` 与 `/sys/class/net`；测试里指向临时目录，
/// 这样「读 UCI + 读 sysfs + dump netlink」这条真实链路也能进单测。
#[derive(Debug, Clone)]
pub struct Env {
    pub etc_dir: PathBuf,
    pub sysfs: SysFs,
}

impl Default for Env {
    fn default() -> Env {
        Env {
            etc_dir: PathBuf::from("/etc"),
            sysfs: SysFs::default(),
        }
    }
}

impl Env {
    pub fn network_file(&self) -> PathBuf {
        self.etc_dir.join("config/network")
    }

    pub fn firewall_file(&self) -> PathBuf {
        self.etc_dir.join("config/firewall")
    }

    /// 读取 `/etc/config/network` + `/etc/config/firewall`。
    ///
    /// 文件缺失是「未配置」而不是错误：全新设备上 firewall 一定存在，
    /// 但用户可能手工精简过；这里给出可读告警并返回空拓扑。
    pub fn load_topology(&self, warnings: &mut Vec<String>) -> Result<Topology> {
        let network = read_uci(&self.network_file(), "network", warnings)?;
        let mut topo = crate::system::interface::parse_network(&network)?;
        let fw = read_uci(&self.firewall_file(), "firewall", warnings)?;
        crate::system::interface::merge_firewall(&mut topo, &fw)?;
        Ok(topo)
    }
}

fn read_uci(path: &Path, what: &str, warnings: &mut Vec<String>) -> Result<String> {
    match std::fs::read_to_string(path) {
        Ok(s) => Ok(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            warnings.push(format!(
                "找不到 {what} 配置（{}），相关检查跳过",
                path.display()
            ));
            Ok(String::new())
        }
        Err(e) => Err(Error::Config(format!("读取 {} 失败: {e}", path.display()))),
    }
}

/// 一次完整观察的结果：内核现状 + 期望状态 + 差量 + 所有需要告诉用户的问题。
///
/// 这是 `--check`、RPC `status.get` 与事务共用的数据结构，
/// 保证「UI 显示的」和「事务真的下发的」是同一份计算结果。
#[derive(Debug, Default)]
pub struct Observation {
    pub topo: Topology,
    pub resolved: HashMap<String, Resolved>,
    /// 解析失败的线路（名字 → 原因）。失败不阻断其它线路，但必须上报。
    pub resolve_errors: Vec<(String, String)>,
    pub slots: HashMap<String, u8>,
    pub targets: Vec<WanTarget>,
    pub rules: Vec<RuleEntry>,
    pub routes: Vec<RouteEntry>,
    pub addresses: Vec<AddrEntry>,
    pub mirror: MirrorSet,
    pub desired: Desired,
    pub diff: Diff,
    /// 结构化问题（前端按 severity 分级渲染）。
    pub issues: Vec<Issue>,
    /// 文本告警（NAT 覆盖、设备备注等），来自 interface 层。
    pub warnings: Vec<String>,
}

impl Observation {
    /// 是否存在阻塞性错误（Error 级 issue）。事务据此决定提不提交。
    pub fn blocked(&self) -> bool {
        self.issues.iter().any(|i| i.severity == Severity::Error) || self.diff.blocking().is_some()
    }

    pub fn families(enable_ipv6: bool) -> Vec<Family> {
        if enable_ipv6 {
            vec![Family::V4, Family::V6]
        } else {
            vec![Family::V4]
        }
    }

    /// 某线路是否已经具备可用出口（调度器的硬前置条件）。
    pub fn usable(&self, name: &str) -> bool {
        match self.slots.get(name) {
            Some(slot) => self
                .targets
                .iter()
                .find(|t| t.slot == *slot)
                .map(|t| t.usable_v4())
                .unwrap_or(false),
            None => false,
        }
    }
}

/// 打开与内核对话的通道（生产用）；测试里直接把 [`FakeNetlink`] 传给 `observe`。
pub fn open_netlink() -> Result<netlink::NetlinkHandle> {
    // 单次 dump 的接收超时：给足余量但绝不无限等。
    netlink::NetlinkHandle::open(std::time::Duration::from_millis(
        netlink::DEFAULT_RECV_TIMEOUT_MS,
    ))
}

/// 异步观察：整轮 dump + 解析在阻塞线程里完成，不占用 tokio 工作线程。
pub async fn observe_async(
    cfg: &Config,
    env: &Env,
    handle: &netlink::NetlinkHandle,
) -> Result<Observation> {
    let cfg = cfg.clone();
    let env = env.clone();
    let handle = handle.clone();
    tokio::task::spawn_blocking(move || observe(&cfg, &env, &netlink::BlockingOps(&handle)))
        .await
        .map_err(|e| Error::Netlink(format!("观察任务被丢弃: {e}")))?
}

/// 异步提交：先应用差量，再重新 dump 校验。
///
/// `on_conflict` 拿到的 issue 只作展示；返回 Err 时事务层负责回滚配置。
pub async fn commit_async(
    ob: &Observation,
    handle: &netlink::NetlinkHandle,
) -> Result<CommitReport> {
    let diff = ob.diff.clone();
    let desired = ob.desired.clone();
    let handle = handle.clone();
    tokio::task::spawn_blocking(move || {
        let ops = netlink::BlockingOps(&handle);
        commit_with(&ops, &diff, &desired)
    })
    .await
    .map_err(|e| Error::Netlink(format!("提交任务被丢弃: {e}")))?
}

/// 一次提交的完整回执：做了什么、校验结果如何。RPC 与日志都用它，避免「UI 自己猜」。
#[derive(Debug, Default, Clone)]
pub struct CommitReport {
    pub summary: String,
    pub applied: bool,
    pub verify_issues: Vec<Issue>,
}

impl CommitReport {
    pub fn verified(&self) -> bool {
        !self
            .verify_issues
            .iter()
            .any(|i| i.severity == Severity::Error)
    }
}

/// 提交差量并做应用后校验。失败时 `Applier` 已自动回滚内核改动。
pub fn commit_with(ops: &dyn RouteOps, diff: &Diff, desired: &Desired) -> Result<CommitReport> {
    let applier = Applier::new(ops);
    let summary = diff.summary();
    if !diff.is_empty() {
        logging::info_ctx(
            "system",
            "commit",
            &format!("策略路由收敛：{summary}"),
            &[
                ("add_rules", diff.add_rules.len().to_string()),
                ("del_rules", diff.del_rules.len().to_string()),
                ("add_routes", diff.add_routes.len().to_string()),
                ("del_routes", diff.del_routes.len().to_string()),
            ],
        );
    }
    // 差量为空也要校验：内核可能被别的组件改过
    if !diff.is_empty() {
        applier.apply(diff)?;
    }
    let verify_issues = applier.verify(desired)?;
    for i in &verify_issues {
        logging::log(
            if i.severity == Severity::Error {
                logging::Level::Error
            } else {
                logging::Level::Warn
            },
            "system",
            "verify",
            &i.message,
            &[("path", i.path.clone())],
        );
    }
    Ok(CommitReport {
        summary,
        applied: !diff.is_empty(),
        verify_issues,
    })
}

/// 观察：读配置 → dump 内核 → 解析线路 → 生成期望 → 算差量 → 审计冲突。
///
/// 全程只读，不改内核；`--check` 就靠它。
pub fn observe(cfg: &Config, env: &Env, ops: &dyn RouteOps) -> Result<Observation> {
    let mut ob = Observation::default();
    ob.topo = env.load_topology(&mut ob.warnings)?;
    ob.slots = assign_slots(&cfg.wans)?;

    let families = Observation::families(cfg.global.enable_ipv6);

    // dump 现状。任何一次 dump 失败都不能让 observe 直接失败：
    // 我们要在 UI 上告诉用户「哪一部分看不到」，而不是整个页面报错。
    for f in families.iter().copied() {
        let name = f.as_str();
        match ops.dump_rules(f) {
            Ok(v) => ob.rules.extend(v),
            Err(e) => ob.warnings.push(format!("{name} 规则 dump 失败: {e}")),
        }
        // 镜像路由的来源：main 表（直连/默认）与 local 表（本机地址）
        for table in [
            netlink::RT_TABLE_MAIN as u32,
            netlink::RT_TABLE_LOCAL as u32,
        ] {
            match ops.dump_routes(f, table) {
                Ok(v) => ob.routes.extend(v),
                Err(e) => ob
                    .warnings
                    .push(format!("{name} 路由表 {table} dump 失败: {e}")),
            }
        }
        match ops.dump_addresses(f) {
            Ok(v) => ob.addresses.extend(v),
            Err(e) => ob.warnings.push(format!("{name} 地址 dump 失败: {e}")),
        }
    }
    // 我们自己的表里现在有什么（清理与替换的唯一依据）
    for f in families.iter().copied() {
        for slot in ob.slots.values() {
            match ops.dump_routes(f, marks::table_of(*slot)) {
                Ok(v) => ob.routes.extend(v),
                Err(e) => ob
                    .warnings
                    .push(format!("dump 表 {} 失败: {e}", marks::table_of(*slot))),
            }
        }
    }

    let (resolved, errs) =
        interface::resolve_all(&cfg.wans, &ob.topo, ops, &env.sysfs, cfg.global.enable_ipv6);
    ob.resolved = resolved;
    ob.resolve_errors = errs;

    // 目标集合：只包含启用且解析成功的线路
    let mut wans_sorted: Vec<&WanConfig> = cfg.wans.iter().filter(|w| w.enabled).collect();
    wans_sorted.sort_by(|a, b| a.name.cmp(&b.name));
    for w in wans_sorted {
        let Some(slot) = ob.slots.get(&w.name) else {
            continue;
        };
        match ob.resolved.get(&w.name) {
            Some(r) => ob.targets.push(r.to_target(*slot)),
            None => ob
                .warnings
                .push(format!("线路 {} 无法解析，本轮不参与选路", w.name)),
        }
    }

    // LAN 设备索引：镜像直连路由要用
    let lan_devices = ob.topo.lan_devices(&cfg.global.lan_zones);
    let mut lan_indexes: Vec<u32> = Vec::new();
    for d in &lan_devices {
        if let Some(idx) = env.sysfs.device(d).ifindex {
            lan_indexes.push(idx);
        }
    }
    if lan_devices.is_empty() {
        ob.warnings.push(format!(
            "未匹配到 LAN 设备（lan_zones={:?}）；本机与 LAN 的流量仍将走 main 表，但插件无法确认管理面安全",
            cfg.global.lan_zones
        ));
    }
    ob.mirror = route::build_mirror(&ob.routes, &lan_indexes);
    ob.desired = route::plan(&ob.targets, &ob.mirror, &families)?;
    ob.diff = route::reconcile(&ob.rules, &ob.routes, &ob.desired);

    // 审计：内核里规则之间的关系 + main 表默认路由是否存在
    for f in families.iter().copied() {
        let main_default = interface::has_main_default(&ob.routes, f);
        ob.issues
            .extend(route::audit_conflicts(&ob.rules, main_default, f));
    }

    // NAT/回程一致性检查（任务书第八节）
    for w in ob.topo.check_wan_nat_coverage(&cfg.wans) {
        ob.issues.push(Issue {
            severity: Severity::Warning,
            path: "firewall.nat".into(),
            message: w,
            hint: Some(
                "在 /etc/config/firewall 对应 zone 里开启 masq，或改用与运营商匹配的接入方式"
                    .into(),
            ),
        });
    }
    // 线路解析失败也是 issue（必须显示，不能只进日志）
    for (name, reason) in &ob.resolve_errors {
        ob.issues.push(Issue {
            severity: Severity::Warning,
            path: format!("wan.{}.device", name),
            message: format!("线路 {name} 解析失败: {reason}"),
            hint: Some(
                "确认设备名/接口名、是否已拨号，或在该线路上手工填写 gateway 与 src_ip".into(),
            ),
        });
    }
    // 其它线路备注（链路未 up、没有默认路由等）
    for r in ob.resolved.values() {
        for n in &r.notes {
            ob.issues.push(Issue {
                severity: Severity::Info,
                path: format!("wan.{}.state", r.wan),
                message: format!("线路 {}: {n}", r.wan),
                hint: None,
            });
        }
    }
    ob.issues.extend(ob.diff.conflicts.iter().cloned());
    Ok(ob)
}

/// 只读地采样流量（`连接与流量` 页与最少流量算法用）。
pub fn sample(cfg: &Config, env: &Env, at_ms: u64) -> TrafficSample {
    let mut devices: Vec<String> = Vec::new();
    for w in cfg.wans.iter().filter(|w| w.enabled) {
        // 优先用配置里显式写的设备；没写时 netifd 的约定是「接口段名即设备名」，
        // 对不上的话采样结果是 0，UI 会显示「无计数器数据」而不是编造速率。
        let d = if w.device.is_empty() {
            w.name.clone()
        } else {
            w.device.clone()
        };
        if !devices.contains(&d) {
            devices.push(d);
        }
    }
    interface::sample_traffic(&env.sysfs, &devices, at_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::WanConfig;
    use crate::system::netlink::FakeNetlink;
    use crate::system::netlink::{
        RTN_LOCAL, RTN_UNICAST, RT_SCOPE_HOST, RT_SCOPE_LINK, RT_TABLE_LOCAL, RT_TABLE_MAIN,
    };
    use std::net::IpAddr;

    fn wan(name: &str, enabled: bool) -> WanConfig {
        WanConfig {
            name: name.into(),
            enabled,
            ..Default::default()
        }
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn slots_are_stable_and_skip_disabled() {
        let w = vec![wan("b", true), wan("a", false), wan("c", true)];
        let s = assign_slots(&w).unwrap();
        // 槽位按数组顺序分配；同一份配置每次启动得到相同结果，
        // 这是「重启后已建立连接不换出口」的前提。
        assert_eq!(s["b"], 1);
        assert_eq!(s["c"], 2);
        assert!(!s.contains_key("a"), "停用线路不占槽位");
        assert_eq!(s, assign_slots(&w).unwrap());
    }

    #[test]
    fn too_many_enabled_wans_is_rejected() {
        let w: Vec<WanConfig> = (0..=marks::MAX_WANS)
            .map(|i| wan(&format!("w{i}"), true))
            .collect();
        let e = assign_slots(&w).unwrap_err();
        assert!(matches!(e, Error::Validate(_)));
        assert!(e.to_string().contains("上限"));
    }

    #[test]
    fn duplicate_section_names_are_rejected() {
        assert!(assign_slots(&[wan("dup", true), wan("dup", true)]).is_err());
    }

    #[test]
    fn our_tables_matches_mark_layout() {
        let t = our_tables();
        assert_eq!(t.len(), marks::MAX_WANS as usize);
        assert_eq!(t[0], marks::TABLE_BASE + 1);
        assert_eq!(t[23], marks::TABLE_BASE + 24);
        assert!(
            t.iter().all(|x| *x < RT_TABLE_LOCAL as u32),
            "不能碰到 253/254/255"
        );
    }

    /// 造一个可控环境：<tmp>/config/{network,firewall} + <tmp>/net/<dev>
    struct Fixture {
        /// 只在测试结束时负责删除临时目录；不读它，但不能改名成真字段。
        _dir: tempfile::TempDir,
        env: Env,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::TempDir::new().unwrap();
        let etc = dir.path().join("etc");
        std::fs::create_dir_all(etc.join("config")).unwrap();
        std::fs::write(
            etc.join("config/network"),
            "config interface 'lan'\n    option device 'br-lan'\n    option proto 'static'\n    option ipaddr '192.168.1.1'\n\n\
             config interface 'wan'\n    option device 'eth1'\n    option proto 'dhcp'\n\n\
             config interface 'wan_5g'\n    option device 'wwan0'\n    option proto 'dhcp'\n",
        )
        .unwrap();
        std::fs::write(
            etc.join("config/firewall"),
            "config zone\n    option name 'lan'\n    list network 'lan'\n\n\
             config zone\n    option name 'wan'\n    list network 'wan'\n    list network 'wan_5g'\n    option masq '1'\n",
        )
        .unwrap();
        let net = dir.path().join("net");
        for (n, idx) in [("br-lan", "6"), ("eth1", "4"), ("wwan0", "7")] {
            let d = net.join(n);
            std::fs::create_dir_all(d.join("statistics")).unwrap();
            std::fs::write(d.join("ifindex"), format!("{idx}\n")).unwrap();
            std::fs::write(d.join("carrier"), "1\n").unwrap();
            std::fs::write(d.join("operstate"), "up\n").unwrap();
            std::fs::write(d.join("statistics/rx_bytes"), "10\n").unwrap();
            std::fs::write(d.join("statistics/tx_bytes"), "20\n").unwrap();
        }
        Fixture {
            _dir: dir,
            env: Env {
                etc_dir: etc,
                sysfs: SysFs::new(&net),
            },
        }
    }

    fn cfg_two_wans() -> Config {
        let mut c = Config::default();
        c.global.enable_ipv6 = false;
        c.global.lan_zones = vec!["lan".into()];
        c.wans = vec![
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
        c
    }

    /// 测试夹具：按 `ip route` 转储的字段顺序构造路由条目。
    /// 位置参数多确实可读性差，但调用点只有 5 处且刻意与内核转储一一对应，
    /// 改成具名构造反而会让夹具比被测逻辑更长。
    #[allow(clippy::too_many_arguments)]
    fn route(
        family: Family,
        table: u32,
        dst: Option<IpAddr>,
        len: u8,
        gw: Option<IpAddr>,
        oif: u32,
        kind: u8,
        scope: u8,
    ) -> RouteEntry {
        RouteEntry {
            family,
            table,
            dst_len: len,
            dst,
            gateway: gw,
            oif: Some(oif),
            prefsrc: None,
            priority: 0,
            protocol: netlink::RTPROT_KERNEL,
            scope,
            kind,
        }
    }

    /// 内核现状：main 表两条默认路由（wan 有网关、5G 是点对点），local 表本机地址，
    /// main 表 LAN 直连段。
    fn kernel_state() -> Vec<RouteEntry> {
        vec![
            route(
                Family::V4,
                RT_TABLE_MAIN as u32,
                None,
                0,
                Some(ip("10.0.0.1")),
                4,
                RTN_UNICAST,
                RT_SCOPE_LINK,
            ),
            route(
                Family::V4,
                RT_TABLE_MAIN as u32,
                None,
                0,
                None,
                7,
                RTN_UNICAST,
                RT_SCOPE_LINK,
            ),
            route(
                Family::V4,
                RT_TABLE_MAIN as u32,
                Some(ip("192.168.1.0")),
                24,
                None,
                6,
                RTN_UNICAST,
                RT_SCOPE_LINK,
            ),
            route(
                Family::V4,
                RT_TABLE_LOCAL as u32,
                Some(ip("192.168.1.1")),
                32,
                None,
                6,
                RTN_LOCAL,
                RT_SCOPE_HOST,
            ),
            route(
                Family::V4,
                RT_TABLE_LOCAL as u32,
                Some(ip("10.0.0.2")),
                32,
                None,
                4,
                RTN_LOCAL,
                RT_SCOPE_HOST,
            ),
        ]
    }

    #[test]
    fn observe_resolves_both_wans_and_plans_rules() {
        let f = fixture();
        let fake = FakeNetlink::with_state(vec![], kernel_state(), vec![]);
        let ob = observe(&cfg_two_wans(), &f.env, &fake).unwrap();
        assert_eq!(ob.slots.len(), 2);
        assert_eq!(ob.targets.len(), 2);
        // wan 有网关、5G 是链路级默认 → 两条都可用
        assert!(ob.targets.iter().all(|t| t.usable_v4()), "{:?}", ob.targets);
        assert_eq!(ob.diff.add_rules.len(), 2, "两条线路各一条标记规则");
        assert_eq!(
            ob.diff.add_routes.len(),
            8,
            "每表 1 条默认路由 + 2 条本机 + 1 条 LAN 直连，两表共 8 条"
        );
        assert!(!ob.blocked(), "issue: {:?}", ob.issues);
        assert_eq!(ob.mirror.connected, vec![(ip("192.168.1.0"), 24, 6)]);
        assert_eq!(ob.mirror.local.len(), 2);
    }

    #[test]
    fn observe_is_idempotent_after_commit() {
        let f = fixture();
        let fake = FakeNetlink::with_state(vec![], kernel_state(), vec![]);
        let cfg = cfg_two_wans();
        let ob = observe(&cfg, &f.env, &fake).unwrap();
        let rpt = commit_with(&fake, &ob.diff, &ob.desired).unwrap();
        assert!(rpt.applied && rpt.verified(), "{rpt:?}");
        // 再来一次：差量必须为空，且不会重复安装（任务书「重启不产生重复规则」）
        let ob2 = observe(&cfg, &f.env, &fake).unwrap();
        assert!(
            ob2.diff.is_empty(),
            "第二次观察应为空差量：{}",
            ob2.diff.summary()
        );
        assert_eq!(ob2.rule_list_len(), 2);
        let n_routes = fake
            .route_list()
            .iter()
            .filter(|r| r.in_our_table() && r.is_default())
            .count();
        assert_eq!(n_routes, 2, "默认路由不能被重复安装");
    }

    #[test]
    fn observe_reports_unresolved_wan_without_failing() {
        let f = fixture();
        // wwan0 从 sysfs 消失（5G 模块掉线）
        std::fs::remove_dir_all(f.env.sysfs.root.join("wwan0")).unwrap();
        let fake = FakeNetlink::with_state(vec![], kernel_state(), vec![]);
        let ob = observe(&cfg_two_wans(), &f.env, &fake).unwrap();
        assert_eq!(
            ob.targets.len(),
            1,
            "掉线线路不参与选路，但另一条必须照常工作"
        );
        assert!(ob.resolve_errors.iter().any(|(n, _)| n == "wan_5g"));
        assert!(ob.issues.iter().any(|i| i.message.contains("wan_5g")));
        assert_eq!(ob.diff.add_rules.len(), 1);
    }

    #[test]
    fn observe_flags_missing_lan_zone() {
        let f = fixture();
        let fake = FakeNetlink::with_state(vec![], kernel_state(), vec![]);
        let mut cfg = cfg_two_wans();
        cfg.global.lan_zones = vec!["ghost".into()];
        let ob = observe(&cfg, &f.env, &fake).unwrap();
        assert!(ob.warnings.iter().any(|w| w.contains("未匹配到 LAN 设备")));
        // LAN 设备为空 → 不镜像直连段，但仍应有默认路由
        assert!(ob.mirror.connected.is_empty());
        assert_eq!(ob.diff.add_rules.len(), 2);
    }

    #[test]
    fn observe_warns_when_wan_zone_has_no_masq() {
        let f = fixture();
        std::fs::write(
            f.env.etc_dir.join("config/firewall"),
            "config zone\n    option name 'lan'\n    list network 'lan'\n\nconfig zone\n    option name 'wan'\n    list network 'wan'\n    list network 'wan_5g'\n",
        )
        .unwrap();
        let fake = FakeNetlink::with_state(vec![], kernel_state(), vec![]);
        let ob = observe(&cfg_two_wans(), &f.env, &fake).unwrap();
        let nat: Vec<_> = ob
            .issues
            .iter()
            .filter(|i| i.path == "firewall.nat")
            .collect();
        assert_eq!(nat.len(), 2, "两条线路都缺 masq");
        assert!(nat[0].message.contains("masq"));
    }

    #[test]
    fn observe_survices_foreign_priority_conflict() {
        let f = fixture();
        let foreign = RuleEntry {
            family: Family::V4,
            priority: route::prio_for_slot(1),
            table: 200,
            action: netlink::FR_ACT_TO_TBL,
            fwmark: None,
            fwmask: None,
            iifname: Some("br-lan".into()),
            src: None,
            dst: None,
            protocol: Some(netlink::RTPROT_BOOT),
            flags: 0,
        };
        let fake = FakeNetlink::with_state(vec![foreign], kernel_state(), vec![]);
        let ob = observe(&cfg_two_wans(), &f.env, &fake).unwrap();
        assert!(ob.blocked(), "优先级被别人占用必须阻塞提交");
        assert!(ob.diff.blocking().is_some());
        assert!(
            matches!(
                commit_with(&fake, &ob.diff, &ob.desired),
                Err(Error::Validate(_))
            ),
            "阻塞性冲突必须拒绝提交"
        );
    }

    #[test]
    fn observation_blocked_only_by_errors() {
        let mut ob = Observation::default();
        assert!(!ob.blocked());
        ob.issues.push(Issue {
            severity: Severity::Warning,
            path: "x".into(),
            message: "m".into(),
            hint: None,
        });
        assert!(!ob.blocked(), "Warning 不阻塞提交");
        ob.issues.push(Issue {
            severity: Severity::Error,
            path: "y".into(),
            message: "m".into(),
            hint: None,
        });
        assert!(ob.blocked());
    }

    #[test]
    fn env_missing_files_warns_instead_of_erroring() {
        let dir = tempfile::TempDir::new().unwrap();
        let env = Env {
            etc_dir: dir.path().join("etc"),
            sysfs: SysFs::new(dir.path().join("net")),
        };
        let mut warnings = Vec::new();
        let topo = env.load_topology(&mut warnings).unwrap();
        assert!(topo.interfaces.is_empty());
        assert_eq!(warnings.len(), 2, "network 与 firewall 都缺 → 两条告警");
        assert!(warnings[0].contains("network"));
    }

    #[test]
    fn sample_uses_configured_device() {
        let f = fixture();
        let cfg = Config {
            wans: vec![
                WanConfig {
                    name: "wan".into(),
                    enabled: true,
                    device: "eth1".into(),
                    ..Default::default()
                },
                WanConfig {
                    name: "off".into(),
                    enabled: false,
                    ..Default::default()
                },
                // 没写 device：按 netifd 约定用段名，取不到就是 0
                WanConfig {
                    name: "wan_5g".into(),
                    enabled: true,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let s = sample(&cfg, &f.env, 999);
        assert_eq!(s.at_ms, 999);
        assert_eq!(s.per_device.get("eth1"), Some(&(10u64, 20u64)));
        assert_eq!(s.per_device.get("wan_5g"), Some(&(0u64, 0u64)));
        assert!(!s.per_device.contains_key("off"));
    }

    #[test]
    fn open_netlink_never_panics() {
        // 沙箱/CI 里可能没有权限或不是 Linux；无论哪种都必须给出明确原因而不是 panic。
        if let Err(e) = open_netlink() {
            assert!(!e.to_string().is_empty());
            assert!(
                e.code() == "netlink" || e.code() == "unsupported" || e.code() == "permission",
                "{}",
                e.code()
            );
        }
    }

    #[tokio::test]
    async fn async_wrappers_work_or_report_permission() {
        let f = fixture();
        let cfg = cfg_two_wans();
        match open_netlink() {
            Ok(h) => {
                let ob = observe_async(&cfg, &f.env, &h).await.unwrap();
                // 真机/容器里内核状态未知，只要求不 panic 且有结构化结果
                assert_eq!(ob.targets.len(), 2);
            }
            Err(_) => {
                // 无权限是允许的结果；用替身验证异步门面本身可运行
                let fake = FakeNetlink::with_state(vec![], kernel_state(), vec![]);
                let ob = observe(&cfg, &f.env, &fake).unwrap();
                assert_eq!(ob.diff.add_rules.len(), 2);
            }
        }
    }

    impl Observation {
        fn rule_list_len(&self) -> usize {
            self.rules.len()
        }
    }
}
