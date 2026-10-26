//! 策略路由层：把「期望状态」收敛到内核，并做冲突审计与安全回滚。
//!
//! 设计要点（对应任务书第八节）：
//!
//! 1. **规则数量恒定**：每个启用线路一条 `ip rule`（v4/v6 各一条），优先级落在
//!    [`RULE_PRIO_BASE`] 起的保留区间，掩码固定为 [`crate::marks::RULE_MASK`]。
//!    负载均衡的桶位变化只改 nft 里的 map，不改内核规则 —— 这是「不做高频全量重建」的实现。
//! 2. **所有权判定用三重条件**：优先级在保留区间 + 掩码等于槽位掩码 +
//!    表号等于 `TABLE_BASE + mark`。任何一条不满足就不删，只报告。
//! 3. **表内容按协议字段区分**：我们只删 `protocol == RTPROT_STATIC`（自己装的）路由；
//!    若用户把 netifd 接口的 `table` 指到同一张表（协议是 dhcp/ra/kernel），
//!    我们保留它们并报冲突，绝不抢别人的路由。
//! 4. **失败即回滚**：收敛产生的每一步都记录逆操作，任一步失败就按逆序撤销，
//!    撤销过程中的错误全部收集进 [`Error::Rollback`]，不静默吞掉。
//! 5. **先加路由后加规则，先删规则后删路由**：任何时刻都不会出现
//!    「规则指向空表」这种把打了标记的流量打成黑洞的状态。
//! 6. **本地/直连路由镜像**：每张 WAN 表都写入本机地址（RTN_LOCAL/RTN_BROADCAST）
//!    和 LAN 直连网段路由，保证「标记包打到 LAN/路由器自身」时仍然正常收发，
//!    这是多 WAN 插件最常见的失联原因之一。

use std::net::IpAddr;

use crate::config::validate::{Issue, Severity};
use crate::marks;
use crate::system::netlink::{
    Family, RouteEntry, RouteOps, RouteSpec, RuleEntry, RuleSpec, RTN_BROADCAST, RTN_LOCAL,
};
use crate::{Error, Result};

/// 本插件保留的规则优先级区间起点。
///
/// 取值 1000 的理由：内核的 `local`(0) 与 netifd/系统默认的 `main`(32765/32766)
/// 与 `default`(32767) 都在我们区间之外，中间有足够空间给用户自定义规则；
/// 同时我们的规则必须早于 `main` 生效，否则标记不产生作用。
pub const RULE_PRIO_BASE: u32 = 1000;

/// 保留区间的宽度：每个槽位占一个优先级。
pub const RULE_PRIO_SPAN: u32 = marks::MAX_WANS as u32;

pub fn is_our_priority(p: u32) -> bool {
    (RULE_PRIO_BASE..RULE_PRIO_BASE + RULE_PRIO_SPAN).contains(&p)
}

/// 槽位 → 规则优先级。槽位从 1 开始，因此 1 号线路用区间起点。
pub fn prio_for_slot(slot: u8) -> u32 {
    assert!((1..=marks::MAX_WANS).contains(&slot), "槽位越界 {slot}");
    RULE_PRIO_BASE + (slot as u32) - 1
}

/// 一条线路的内核侧目标信息（由 `interface.rs` 解析后传入）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WanTarget {
    /// UCI 段名，用于日志/RPC。
    pub name: String,
    pub slot: u8,
    pub device: String,
    pub ifindex: u32,
    pub gw4: Option<IpAddr>,
    pub src4: Option<IpAddr>,
    pub gw6: Option<IpAddr>,
    pub src6: Option<IpAddr>,
    /// 点对点/蜂窝链路：main 表里只有 `default dev wwan0 scope link`（没有网关）。
    /// 为 true 时本插件也在自己的表里装同样形式的默认路由，而不是硬造一个网关。
    pub link_default: bool,
}

impl WanTarget {
    /// 是否具备 v4 出口条件。5G 模块重拨后网关会变，这里两者都没有时
    /// 调度器必须把该线路视为不可用（而不是装一条没有网关的默认路由）。
    pub fn usable_v4(&self) -> bool {
        self.gw4.is_some() || self.link_default
    }

    pub fn usable_v6(&self) -> bool {
        self.gw6.is_some()
    }
}

/// 需要镜像进每张 WAN 表的本机/直连路由。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MirrorSet {
    /// 本机地址（来自 main/local 表的 RTN_LOCAL、RTN_BROADCAST）。
    pub local: Vec<(IpAddr, u32)>,
    /// LAN 直连网段（前缀 + 出接口索引）。
    pub connected: Vec<(IpAddr, u8, u32)>,
}

/// 期望状态。
#[derive(Debug, Clone, Default)]
pub struct Desired {
    pub rules: Vec<RuleSpec>,
    pub routes: Vec<RouteSpec>,
}

/// 收敛计划。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Diff {
    pub add_rules: Vec<RuleSpec>,
    pub del_rules: Vec<RuleSpec>,
    pub add_routes: Vec<RouteSpec>,
    pub del_routes: Vec<RouteSpec>,
    /// 与其它组件冲突的客观事实；`Error` 级别时调用方必须拒绝提交。
    pub conflicts: Vec<Issue>,
}

impl Diff {
    pub fn is_empty(&self) -> bool {
        self.add_rules.is_empty()
            && self.del_rules.is_empty()
            && self.add_routes.is_empty()
            && self.del_routes.is_empty()
    }

    /// 供 RPC/UI 展示的一行摘要。
    pub fn summary(&self) -> String {
        format!(
            "规则 +{}/-{}，路由 +{}/-{}，冲突 {}",
            self.add_rules.len(),
            self.del_rules.len(),
            self.add_routes.len(),
            self.del_routes.len(),
            self.conflicts.len()
        )
    }

    /// 存在 Error 级冲突时不允许提交。
    pub fn blocking(&self) -> Option<String> {
        self.conflicts
            .iter()
            .find(|i| i.severity == Severity::Error)
            .map(|i| i.message.clone())
    }
}

/// 由线路集合生成期望的规则与路由。
///
/// `families` 决定是否为 IPv6 安装对象；关闭 IPv6 时**必须**仍然保证
/// v6 流量走 main 表（不装标记规则即天然如此），而不是「装了规则但没有路由」。
pub fn plan(targets: &[WanTarget], mirror: &MirrorSet, families: &[Family]) -> Result<Desired> {
    if targets.is_empty() {
        return Ok(Desired::default());
    }
    let mut seen_slots: Vec<u8> = Vec::new();
    let mut d = Desired::default();
    for t in targets {
        if t.slot == 0 || t.slot > marks::MAX_WANS {
            return Err(Error::Config(format!(
                "线路 {} 的槽位 {} 非法",
                t.name, t.slot
            )));
        }
        if seen_slots.contains(&t.slot) {
            return Err(Error::Config(format!("槽位 {} 被重复使用", t.slot)));
        }
        seen_slots.push(t.slot);
        let table = marks::table_of(t.slot);
        let prio = prio_for_slot(t.slot);

        // 关键安全约束：某条线路在该地址族上既没有网关又没有链路级默认路由时，
        // **既不装规则也不装路由**。只装规则会把打标记的流量指向空表 → 黑洞；
        // 这是 5G 未拨号/断线期间的常态。
        let has_v4 = families.contains(&Family::V4) && (t.gw4.is_some() || t.link_default);
        let has_v6 = families.contains(&Family::V6) && t.gw6.is_some();
        if !has_v4 && !has_v6 {
            continue;
        }
        if has_v4 {
            d.rules.push(RuleSpec {
                family: Family::V4,
                priority: prio,
                table,
                fwmark: t.slot as u32,
                fwmask: marks::RULE_MASK,
            });
            // 有网关走网关；点对点蜂窝链路（`default dev wwan0 scope link`）没有网关，
            // 就装同样形式的默认路由，绝不编造一个网关地址。
            match t.gw4 {
                Some(gw) => d
                    .routes
                    .push(RouteSpec::default_v4(table, gw, t.ifindex, t.src4)),
                None => d
                    .routes
                    .push(RouteSpec::default_dev(table, t.ifindex, t.src4)),
            }
        }
        if has_v6 {
            let gw = t.gw6.expect("上面已判断");
            d.rules.push(RuleSpec {
                family: Family::V6,
                priority: prio,
                table,
                fwmark: t.slot as u32,
                fwmask: marks::RULE_MASK,
            });
            d.routes.push(RouteSpec {
                family: Family::V6,
                table,
                dst: None,
                dst_len: 0,
                gateway: Some(gw),
                oif: Some(t.ifindex),
                prefsrc: t.src6,
                kind: crate::system::netlink::RTN_UNICAST,
                // 带网关 ⇒ global scope（同 default_v4 的说明：link scope 会被
                // 内核以 ENETUNREACH 拒绝）。
                scope: crate::system::netlink::RT_SCOPE_UNIVERSE,
                priority: 1024,
            });
        }
        // 镜像路由：按地址族分发
        for (addr, owner_ifindex) in &mirror.local {
            let is4 = Family::of(*addr) == Family::V4;
            let ok = (is4 && has_v4) || (!is4 && has_v6);
            if !ok {
                continue;
            }
            d.routes.push(RouteSpec {
                family: Family::of(*addr),
                table,
                dst: Some(*addr),
                dst_len: if Family::of(*addr) == Family::V4 {
                    32
                } else {
                    128
                },
                gateway: None,
                // 本机地址必须挂在它真正所属的接口上：把 br-lan 的地址写成
                // “从 wwan0 出”会让内核校验失败，也会让排查时被误导。
                oif: Some(*owner_ifindex),
                prefsrc: None,
                kind: RTN_LOCAL,
                scope: crate::system::netlink::RT_SCOPE_HOST,
                priority: 0,
            });
        }
        for (addr, len, idx) in &mirror.connected {
            let is4 = Family::of(*addr) == Family::V4;
            let ok = (is4 && has_v4) || (!is4 && has_v6);
            if !ok {
                continue;
            }
            d.routes.push(RouteSpec {
                family: Family::of(*addr),
                table,
                dst: Some(*addr),
                dst_len: *len,
                gateway: None,
                oif: Some(*idx),
                prefsrc: None,
                kind: crate::system::netlink::RTN_UNICAST,
                scope: crate::system::netlink::RT_SCOPE_LINK,
                priority: 0,
            });
        }
    }
    dedup_routes(&mut d.routes);
    Ok(d)
}

/// 同一 (族, 表, 前缀) 只保留一份，避免镜像集合里有重复导致内核重复装载失败。
fn dedup_routes(routes: &mut Vec<RouteSpec>) {
    let mut seen: Vec<(u8, u32, Option<IpAddr>, u8)> = Vec::new();
    routes.retain(|r| {
        let key = (r.family.af(), r.table, r.dst, r.dst_len);
        if seen.contains(&key) {
            false
        } else {
            seen.push(key);
            true
        }
    });
}

/// 从内核 dump 出来的路由里挑出需要镜像的本机/直连条目。
///
/// 输入是 main(254)/local(255) 表的路由全集与 LAN 设备索引集合。
/// 只取「确定不会把 WAN 流量吸进来」的条目：
/// * `RTN_LOCAL` / `RTN_BROADCAST`：本机地址，接受而不转发；
/// * `RTN_UNICAST` 且 `scope == LINK` 且出接口在 LAN 集合内：直连网段。
pub fn build_mirror(routes: &[RouteEntry], lan_ifindex: &[u32]) -> MirrorSet {
    let mut m = MirrorSet::default();
    for r in routes {
        let Some(dst) = r.dst else { continue };
        if r.kind == RTN_LOCAL || r.kind == RTN_BROADCAST {
            if let Some(oif) = r.oif {
                // 去重：同一地址在 local 表里可能出现多条（不同表/优先级）。
                if !m.local.contains(&(dst, oif)) {
                    m.local.push((dst, oif));
                }
            }
            continue;
        }
        if r.kind == crate::system::netlink::RTN_UNICAST
            && r.scope == crate::system::netlink::RT_SCOPE_LINK
        {
            if let Some(oif) = r.oif {
                if lan_ifindex.contains(&oif) {
                    let key = (dst, r.dst_len, oif);
                    if !m.connected.contains(&key) {
                        m.connected.push(key);
                    }
                }
            }
        }
    }
    m
}

/// 计算收敛差量。
///
/// `actual_*` 是内核现状（已经按族 dump）。注意本函数**只读**，
/// 因此可以在 apply 之前把结果给用户看（「变更摘要」），也可以在
/// apply 之后再算一次用于校验（应为空）。
pub fn reconcile(
    actual_rules: &[RuleEntry],
    actual_routes: &[RouteEntry],
    desired: &Desired,
) -> Diff {
    let mut diff = Diff::default();

    // ---- 规则 ----
    for want in &desired.rules {
        let have = actual_rules.iter().any(|r| rule_matches(r, want));
        if !have {
            // 同优先级是否已被别人的规则占用？占用时不能盲装（会产生
            // 两条同优先级规则，命中顺序变成插入顺序，行为不可预测）。
            if let Some(taken) = actual_rules
                .iter()
                .find(|r| r.family == want.family && r.priority == want.priority)
            {
                diff.conflicts.push(Issue {
                    severity: Severity::Error,
                    path: format!("route.rule.{}.{}", want.family.as_str(), want.priority),
                    message: format!(
                        "优先级 {} 已被其它规则占用（表 {}{}），无法安装本插件的标记规则",
                        want.priority,
                        taken.table,
                        taken
                            .iifname
                            .as_ref()
                            .map(|i| format!("，接口 {i}"))
                            .unwrap_or_default()
                    ),
                    hint: Some("请把其它组件的规则移出优先级 1000-1023，或停用冲突的规则".into()),
                });
                continue;
            }
            diff.add_rules.push(want.clone());
        }
    }
    for have in actual_rules {
        if !have.is_ours() {
            continue;
        }
        let keep = desired.rules.iter().any(|w| rule_matches(have, w));
        if !keep {
            let Some(mark) = have.fwmark else { continue };
            diff.del_rules.push(RuleSpec {
                family: have.family,
                priority: have.priority,
                table: have.table,
                fwmark: mark,
                fwmask: have.fwmask.unwrap_or(marks::RULE_MASK),
            });
        }
    }

    // ---- 路由 ----
    for want in &desired.routes {
        let have = actual_routes.iter().any(|r| route_matches(r, want));
        if !have {
            diff.add_routes.push(want.clone());
        }
    }
    for have in actual_routes {
        if !have.in_our_table() {
            continue;
        }
        // 只清理自己装的路由；别人装进同一张表的保留并报冲突。
        if have.protocol != crate::system::netlink::OUR_RTPROT {
            diff.conflicts.push(Issue {
                severity: Severity::Warning,
                path: format!("route.table.{}", have.table),
                message: format!(
                    "表 {} 中存在非本插件安装的路由 {}（协议 {}），已保留不动",
                    have.table,
                    have.prefix_text(),
                    have.protocol
                ),
                hint: Some("如果这是 netifd 的 table 设置，请为该机接口分配别的表号".into()),
            });
            continue;
        }
        let keep = desired.routes.iter().any(|w| route_matches(have, w));
        if !keep {
            diff.del_routes.push(RouteSpec {
                family: have.family,
                table: have.table,
                dst: have.dst,
                dst_len: have.dst_len,
                gateway: have.gateway,
                oif: have.oif,
                prefsrc: have.prefsrc,
                kind: have.kind,
                scope: have.scope,
                priority: have.priority,
            });
        }
    }
    diff
}

fn rule_matches(have: &RuleEntry, want: &RuleSpec) -> bool {
    have.family == want.family
        && have.priority == want.priority
        && have.table == want.table
        && have.fwmark == Some(want.fwmark)
        && have.fwmask == Some(want.fwmask)
}

fn route_matches(have: &RouteEntry, want: &RouteSpec) -> bool {
    have.family == want.family
        && have.table == want.table
        && have.dst == want.dst
        && have.dst_len == want.dst_len
        && have.kind == want.kind
        // 网关/出接口不同视为「不同路由」，需要替换：这正是 5G 重拨后最常见的情况
        && have.gateway == want.gateway
        && have.oif == want.oif
        && have.prefsrc == want.prefsrc
}

/// 全局规则审计：不看我们的期望，只看内核里规则之间的关系，
/// 用于「运行总览」页的冲突提示（任务书第十二节「优先级/掩码冲突审计」）。
///
/// `main_default` 表示该地址族的 main 表里存在默认路由 —— 没有它时，
/// 所有「未标记」和「旁路」流量都不可达，插件本身不该为此负责，但必须报告。
pub fn audit_conflicts(rules: &[RuleEntry], main_default: bool, family: Family) -> Vec<Issue> {
    let mut out = Vec::new();
    // 1. 同族同优先级的重复规则：命中顺序变成插入顺序，行为不可预测
    let mut reported: Vec<u32> = Vec::new();
    for r in rules.iter().filter(|r| r.family == family) {
        if reported.contains(&r.priority) {
            continue;
        }
        let dup = rules
            .iter()
            .filter(|o| o.family == r.family && o.priority == r.priority)
            .count();
        if dup > 1 {
            reported.push(r.priority);
            out.push(Issue {
                severity: Severity::Warning,
                path: format!("route.priority.{}", r.priority),
                message: format!(
                    "{} 存在 {dup} 条同优先级 {} 的规则，命中顺序取决于插入顺序，行为不稳定",
                    r.family.as_str(),
                    r.priority
                ),
                hint: Some("为规则分配互不相同的优先级".into()),
            });
        }
    }
    // 2. 别人的 fwmark 规则落进我们的保留区间：必须报告，且我们不会去删它
    for r in rules.iter().filter(|r| r.family == family) {
        if is_our_priority(r.priority) && r.fwmark.is_some() && !r.is_ours() {
            out.push(Issue {
                severity: Severity::Error,
                path: format!("route.priority.{}", r.priority),
                message: format!(
                    "{} 优先级 {} 上存在他人安装的 fwmark 规则（值 0x{:08x}，掩码 0x{:08x}，表 {}），与本插件的标记区间重叠",
                    r.family.as_str(),
                    r.priority,
                    r.fwmark.unwrap_or(0),
                    r.fwmask.unwrap_or(0),
                    r.table
                ),
                hint: Some(
                    "把该规则移出优先级 1000-1023，或停用产生它的组件（常见来源：mwan3、手工 ip rule、其它多 WAN 插件）"
                        .into(),
                ),
            });
        }
    }
    // 3. main 表没有默认路由
    if !main_default {
        out.push(Issue {
            severity: Severity::Warning,
            path: format!("route.main.{}", family.as_str()),
            message: format!(
                "{} 的 main 表没有默认路由；未标记流量（本机进程、旁路目标）将不可达",
                family.as_str()
            ),
            hint: Some("检查 netifd 是否正常拨号（本插件不会替 netifd 写 main 表）".into()),
        });
    }
    out
}

/// 一条已执行操作对应的撤销动作。
///
/// 方向必须显式记录：「我们装上去的」撤销是删除，
/// 「我们删掉的」撤销是重新装回去 —— 后者在 5G 重拨导致规则被替换时很关键，
/// 回滚不能把用户原本还在工作的旧规则也一并删掉。
#[derive(Debug, Clone)]
pub enum Undo {
    InstalledRule(RuleSpec),
    RemovedRule(RuleSpec),
    InstalledRoute(RouteSpec),
    RemovedRoute(RouteSpec),
}

/// 收敛执行器：按安全顺序下发，并记录逆操作。
pub struct Applier<'a> {
    ops: &'a dyn RouteOps,
}

impl<'a> Applier<'a> {
    pub fn new(ops: &'a dyn RouteOps) -> Applier<'a> {
        Applier { ops }
    }

    /// 应用差量。失败时自动回滚已成功的步骤。
    ///
    /// 返回的错误里同时带上「原始失败原因」和「回滚过程中的遗留问题」，
    /// 运维人员不需要翻日志就能知道内核现在是什么状态。
    pub fn apply(&self, diff: &Diff) -> Result<Vec<Undo>> {
        if let Some(msg) = diff.blocking() {
            return Err(Error::Validate(format!(
                "存在阻塞性冲突，已拒绝提交：{msg}"
            )));
        }
        let mut undo: Vec<Undo> = Vec::new();
        if let Err(e) = self.do_apply(diff, &mut undo) {
            let mut leftovers = Vec::new();
            self.rollback(&mut undo, &mut leftovers);
            let joined = crate::clamp_str(&leftovers.join("; "), 512);
            if leftovers.is_empty() {
                return Err(e);
            }
            return Err(Error::Rollback(format!(
                "提交失败（{e}），已回滚，但回滚过程仍有遗留问题：{joined}"
            )));
        }
        Ok(undo)
    }

    fn do_apply(&self, diff: &Diff, undo: &mut Vec<Undo>) -> Result<()> {
        // 顺序：删旧规则 → 删旧路由 → 加新路由 → 加新规则。
        // 这样任何中间状态下都不会出现「规则指向空表」。
        for spec in &diff.del_rules {
            self.ops.del_rule(spec)?;
            undo.push(Undo::RemovedRule(spec.clone()));
        }
        for spec in &diff.del_routes {
            self.ops.del_route(spec)?;
            undo.push(Undo::RemovedRoute(spec.clone()));
        }
        for spec in &diff.add_routes {
            match self.ops.add_route(spec) {
                Ok(()) => undo.push(Undo::InstalledRoute(spec.clone())),
                Err(e) => {
                    return Err(Error::NoRoute {
                        wan: format!("table {}", spec.table),
                        reason: format!("安装路由失败: {e}"),
                    });
                }
            }
        }
        for spec in &diff.add_rules {
            self.ops.add_rule(spec)?;
            undo.push(Undo::InstalledRule(spec.clone()));
        }
        Ok(())
    }

    /// 逆序撤销。撤销过程中的每个错误都收集进 `leftovers`，由调用方决定怎么呈现。
    pub fn rollback(&self, undo: &mut Vec<Undo>, leftovers: &mut Vec<String>) {
        while let Some(u) = undo.pop() {
            let r = match &u {
                Undo::InstalledRule(s) => self.ops.del_rule(s),
                Undo::RemovedRule(s) => self.ops.add_rule(s),
                Undo::InstalledRoute(s) => self.ops.del_route(s),
                Undo::RemovedRoute(s) => self.ops.add_route(s),
            };
            if let Err(e) = r {
                let desc = match &u {
                    Undo::InstalledRule(s) => {
                        format!("删除已安装规则 prio {} 失败: {e}", s.priority)
                    }
                    Undo::RemovedRule(s) => format!("恢复被删除规则 prio {} 失败: {e}", s.priority),
                    Undo::InstalledRoute(s) => {
                        format!("删除已安装路由 table {} 失败: {e}", s.table)
                    }
                    Undo::RemovedRoute(s) => format!("恢复被删除路由 table {} 失败: {e}", s.table),
                };
                leftovers.push(desc);
            }
        }
    }

    /// 应用后校验：再 dump 一次，期望的差量必须为空。
    pub fn verify(&self, desired: &Desired) -> Result<Vec<Issue>> {
        let mut actual_rules = Vec::new();
        let mut actual_routes = Vec::new();
        for f in [Family::V4, Family::V6] {
            match self.ops.dump_rules(f) {
                Ok(v) => actual_rules.extend(v),
                Err(e) => return Err(Error::Rollback(format!("校验时无法 dump 规则: {e}"))),
            }
            // 只 dump 我们关心的表：表号由槽位决定，最多 24 张。
            for slot in 1..=marks::MAX_WANS {
                let table = marks::table_of(slot);
                match self.ops.dump_routes(f, table) {
                    Ok(v) => actual_routes.extend(v),
                    Err(e) => {
                        return Err(Error::Rollback(format!(
                            "校验时无法 dump 路由表 {table}: {e}"
                        )))
                    }
                }
            }
        }
        let left = reconcile(&actual_rules, &actual_routes, desired);
        let mut issues = Vec::new();
        if !left.is_empty() {
            issues.push(Issue {
                severity: Severity::Error,
                path: "route.verify".into(),
                message: format!(
                    "提交后校验未通过：{}（内核对象被其它组件改动，或安装被拒绝）",
                    left.summary()
                ),
                hint: Some("查看日志中的 netlink 错误码；必要时停用插件排查".into()),
            });
        }
        issues.extend(left.conflicts);
        Ok(issues)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::system::netlink::{
        FakeNetlink, FR_ACT_TO_TBL, OUR_RTPROT, RTN_LOCAL, RTN_UNICAST, RTPROT_KERNEL,
        RT_SCOPE_HOST, RT_SCOPE_LINK, RT_SCOPE_UNIVERSE,
    };
    use std::net::Ipv4Addr;

    /// 带网关的默认路由必须是 global scope。写成 link scope 时内核以
    /// ENETUNREACH 拒绝安装（真机集成测试实测；FakeNetlink 不验证所以单测看不到）。
    #[test]
    fn gateway_default_routes_use_universe_scope() {
        let via_gw = RouteSpec::default_v4(101, v4("192.168.100.1"), 2, None);
        assert_eq!(via_gw.scope, RT_SCOPE_UNIVERSE);
        // 无网关的链路级默认路由（点对点蜂窝）保持 link scope。
        let on_link = RouteSpec::default_dev(101, 2, None);
        assert_eq!(on_link.scope, RT_SCOPE_LINK);
        // plan 产出的 v4/v6 网关路由同样必须是 universe。
        let t = target(1, "wan", "eth0", "192.168.100.1");
        let d = plan(&[t], &MirrorSet::default(), &[Family::V4, Family::V6]).unwrap();
        for r in d.routes.iter().filter(|r| r.gateway.is_some()) {
            assert_eq!(r.scope, RT_SCOPE_UNIVERSE, "{r:?} 带网关却用 link scope");
        }
    }

    fn v4(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    fn target(slot: u8, name: &str, dev: &str, gw: &str) -> WanTarget {
        WanTarget {
            name: name.into(),
            slot,
            device: dev.into(),
            ifindex: slot as u32 + 3,
            gw4: Some(v4(gw)),
            src4: Some(v4("192.168.100.1")),
            gw6: None,
            src6: None,
            link_default: false,
        }
    }

    fn our_rule(slot: u8, family: Family) -> RuleEntry {
        RuleEntry {
            family,
            priority: prio_for_slot(slot),
            table: marks::table_of(slot),
            action: FR_ACT_TO_TBL,
            fwmark: Some(slot as u32),
            fwmask: Some(marks::RULE_MASK),
            iifname: None,
            src: None,
            dst: None,
            protocol: Some(OUR_RTPROT),
            flags: 0,
        }
    }

    #[test]
    fn priority_band_is_disjoint_from_system_rules() {
        // 系统默认规则：0(local)、32766(main)、32767(default) 都不能落进我们的区间。
        for p in [0u32, 100, 32766, 32767] {
            assert!(!is_our_priority(p), "{p} 不应被判定为本插件保留");
        }
        assert_eq!(prio_for_slot(1), RULE_PRIO_BASE);
        assert_eq!(prio_for_slot(24), RULE_PRIO_BASE + 23);
        assert!(is_our_priority(prio_for_slot(24)));
        assert!(!is_our_priority(prio_for_slot(24) + 1));
    }

    #[test]
    fn plan_creates_one_rule_per_wan_and_default_route() {
        let ts = vec![
            target(1, "wan1", "eth1", "10.0.0.1"),
            target(2, "wan2", "ppp0", "10.1.1.1"),
        ];
        let d = plan(&ts, &MirrorSet::default(), &[Family::V4]).unwrap();
        assert_eq!(d.rules.len(), 2);
        assert_eq!(d.routes.len(), 2);
        assert!(d.rules.iter().all(|r| r.fwmask == marks::RULE_MASK));
        assert_eq!(d.rules[0].table, 101);
        assert_eq!(d.rules[1].table, 102);
        assert_eq!(d.rules[0].priority, prio_for_slot(1));
    }

    #[test]
    fn plan_skips_family_when_disabled_and_marks_unusable() {
        let ts = vec![target(1, "wan1", "eth1", "10.0.0.1")];
        let d6 = plan(&ts, &MirrorSet::default(), &[Family::V6]).unwrap();
        // v6 网关未知：装规则但不装默认路由是危险的，因此两者都不装。
        assert!(d6.rules.is_empty(), "没有 v6 网关时不得留下指向空表的规则");
        assert!(d6.routes.is_empty());
    }

    #[test]
    fn plan_rejects_duplicate_and_out_of_range_slots() {
        let ts = vec![
            target(1, "a", "eth1", "10.0.0.1"),
            target(1, "b", "eth2", "10.0.1.1"),
        ];
        assert!(plan(&ts, &MirrorSet::default(), &[Family::V4]).is_err());
        let bad = vec![WanTarget {
            slot: 25,
            ..target(1, "a", "eth1", "10.0.0.1")
        }];
        assert!(plan(&bad, &MirrorSet::default(), &[Family::V4]).is_err());
    }

    #[test]
    fn reconcile_adds_missing_and_leaves_existing() {
        let ts = vec![target(1, "wan1", "eth1", "10.0.0.1")];
        let d = plan(&ts, &MirrorSet::default(), &[Family::V4]).unwrap();
        let empty = reconcile(&[], &[], &d);
        assert_eq!(empty.add_rules.len(), 1);
        assert_eq!(empty.add_routes.len(), 1);
        assert!(empty.del_rules.is_empty());
        assert_eq!(empty.summary(), "规则 +1/-0，路由 +1/-0，冲突 0");
        // 已就位：差量应为空
        let routes: Vec<RouteEntry> = d
            .routes
            .iter()
            .map(|r| RouteEntry {
                family: r.family,
                table: r.table,
                dst_len: r.dst_len,
                dst: r.dst,
                gateway: r.gateway,
                oif: r.oif,
                prefsrc: r.prefsrc,
                priority: r.priority,
                protocol: OUR_RTPROT,
                scope: r.scope,
                kind: r.kind,
            })
            .collect();
        let rules: Vec<RuleEntry> = vec![our_rule(1, Family::V4)];
        let settled = reconcile(&rules, &routes, &d);
        assert!(
            settled.is_empty(),
            "收敛后不应产生二次改动：{:?}",
            settled.summary()
        );
    }

    #[test]
    fn reconcile_removes_stale_gateway_but_keeps_foreign_protocols() {
        let ts = vec![target(1, "wan1", "eth1", "10.0.0.9")];
        let d = plan(&ts, &MirrorSet::default(), &[Family::V4]).unwrap();
        // 内核里有一条旧的默认路由（我们装的）和一条 netifd dhcp 装的
        let old = RouteEntry {
            family: Family::V4,
            table: 101,
            dst_len: 0,
            dst: None,
            gateway: Some(v4("10.0.0.1")),
            oif: Some(4),
            prefsrc: None,
            priority: 1024,
            protocol: OUR_RTPROT,
            scope: RT_SCOPE_LINK,
            kind: RTN_UNICAST,
        };
        let foreign = RouteEntry {
            protocol: crate::system::netlink::RTPROT_DHCP,
            table: 101,
            dst: Some(v4("10.0.0.0")),
            dst_len: 24,
            gateway: None,
            kind: RTN_UNICAST,
            scope: RT_SCOPE_LINK,
            oif: Some(4),
            prefsrc: None,
            priority: 0,
            family: Family::V4,
        };
        let diff = reconcile(&[our_rule(1, Family::V4)], &[old, foreign], &d);
        assert_eq!(diff.del_routes.len(), 1, "自己的旧默认路由要被替换");
        assert_eq!(diff.add_routes.len(), 1);
        assert_eq!(diff.conflicts.len(), 1);
        assert_eq!(diff.conflicts[0].severity, Severity::Warning);
        assert!(
            diff.conflicts[0].message.contains("dhcp")
                || diff.conflicts[0].message.contains("协议 16")
        );
    }

    #[test]
    fn reconcile_reports_blocking_conflict_on_taken_priority() {
        let ts = vec![target(1, "wan1", "eth1", "10.0.0.1")];
        let d = plan(&ts, &MirrorSet::default(), &[Family::V4]).unwrap();
        let foreign = RuleEntry {
            family: Family::V4,
            priority: prio_for_slot(1),
            table: 200,
            action: FR_ACT_TO_TBL,
            fwmark: None,
            fwmask: None,
            iifname: Some("br-lan".into()),
            src: None,
            dst: None,
            protocol: Some(OUR_RTPROT),
            flags: 0,
        };
        let diff = reconcile(&[foreign], &[], &d);
        assert!(diff.add_rules.is_empty());
        assert_eq!(diff.conflicts[0].severity, Severity::Error);
        assert!(diff.blocking().is_some());
    }

    #[test]
    fn foreign_stale_rule_is_never_deleted() {
        // 别人的规则恰好在我们区间内但不是我们的形状：del_rules 必须为空
        let other = RuleEntry {
            family: Family::V4,
            priority: prio_for_slot(3),
            table: 300,
            action: FR_ACT_TO_TBL,
            fwmark: Some(3),
            fwmask: Some(0xffffffff),
            iifname: None,
            src: None,
            dst: None,
            protocol: None,
            flags: 0,
        };
        let d = Desired::default();
        let diff = reconcile(&[other], &[], &d);
        assert!(diff.del_rules.is_empty(), "绝不能删除所有权不明确的规则");
    }

    #[test]
    fn applier_rolls_back_everything_when_a_step_fails() {
        let fake = FakeNetlink::new();
        // 第三个 add_rule 注入失败：前两步必须被撤销
        {
            let mut q = fake.fail_add_rule.lock().unwrap();
            q.extend(vec![None, Some("EINVAL：内核拒绝了参数".into())]);
        }
        let diff = Diff {
            add_rules: vec![
                RuleSpec {
                    family: Family::V4,
                    priority: 1000,
                    table: 101,
                    fwmark: 1,
                    fwmask: 0xff,
                },
                RuleSpec {
                    family: Family::V4,
                    priority: 1001,
                    table: 102,
                    fwmark: 2,
                    fwmask: 0xff,
                },
            ],
            add_routes: vec![RouteSpec::default_v4(
                101,
                IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
                4,
                None,
            )],
            ..Diff::default()
        };
        let ap = Applier::new(&fake);
        let err = ap.apply(&diff).unwrap_err();
        assert!(matches!(err, Error::Netlink(_)));
        assert!(
            fake.rule_list().is_empty(),
            "回滚后不应留下任何规则，实际 {:?}",
            fake.logged()
        );
        assert!(fake.route_list().is_empty(), "回滚后不应留下任何路由");
    }

    #[test]
    fn applier_refuses_blocking_conflicts_without_touching_kernel() {
        let fake = FakeNetlink::new();
        let diff = Diff {
            conflicts: vec![Issue {
                severity: Severity::Error,
                path: "x".into(),
                message: "优先级冲突".into(),
                hint: None,
            }],
            add_rules: vec![RuleSpec {
                family: Family::V4,
                priority: 1000,
                table: 101,
                fwmark: 1,
                fwmask: 0xff,
            }],
            ..Diff::default()
        };
        let ap = Applier::new(&fake);
        assert!(matches!(ap.apply(&diff), Err(Error::Validate(_))));
        assert!(fake.logged().is_empty());
    }

    #[test]
    fn applier_succeeds_and_verify_is_clean() {
        let fake = FakeNetlink::new();
        let ts = vec![target(1, "wan1", "eth1", "10.0.0.1")];
        let d = plan(&ts, &MirrorSet::default(), &[Family::V4]).unwrap();
        let diff = reconcile(&[], &[], &d);
        Applier::new(&fake).apply(&diff).unwrap();
        let issues = Applier::new(&fake).verify(&d).unwrap();
        assert!(issues.is_empty(), "校验应无问题：{:?}", issues);
    }

    #[test]
    fn verify_detects_external_tampering() {
        let fake = FakeNetlink::new();
        let ts = vec![target(1, "wan1", "eth1", "10.0.0.1")];
        let d = plan(&ts, &MirrorSet::default(), &[Family::V4]).unwrap();
        Applier::new(&fake).apply(&reconcile(&[], &[], &d)).unwrap();
        // 外部把规则删掉了
        fake.clear_rules();
        let issues = Applier::new(&fake).verify(&d).unwrap();
        assert!(!issues.is_empty());
        assert!(issues[0].message.contains("提交后校验未通过"));
    }

    #[test]
    fn mirror_only_takes_local_and_lan_connected() {
        let routes = vec![
            RouteEntry {
                family: Family::V4,
                table: 255,
                dst_len: 32,
                dst: Some(v4("192.168.1.1")),
                gateway: None,
                oif: Some(1),
                prefsrc: None,
                priority: 0,
                protocol: RTPROT_KERNEL,
                scope: RT_SCOPE_HOST,
                kind: RTN_LOCAL,
            },
            RouteEntry {
                family: Family::V4,
                table: 254,
                dst_len: 24,
                dst: Some(v4("192.168.1.0")),
                gateway: None,
                oif: Some(6),
                prefsrc: None,
                priority: 0,
                protocol: RTPROT_KERNEL,
                scope: RT_SCOPE_LINK,
                kind: RTN_UNICAST,
            },
            // WAN 直连段绝不能被镜像（否则 WAN 表会吸走 LAN 段流量）
            RouteEntry {
                family: Family::V4,
                table: 254,
                dst_len: 24,
                dst: Some(v4("10.0.0.0")),
                gateway: None,
                oif: Some(7),
                prefsrc: None,
                priority: 0,
                protocol: RTPROT_KERNEL,
                scope: RT_SCOPE_LINK,
                kind: RTN_UNICAST,
            },
        ];
        let m = build_mirror(&routes, &[6]);
        assert_eq!(m.local.len(), 1);
        assert_eq!(m.connected.len(), 1);
        assert_eq!(m.connected[0].0, v4("192.168.1.0"));
        assert!(m.connected.iter().all(|(_, _, i)| *i == 6));
    }

    #[test]
    fn mirrored_routes_land_in_every_wan_table() {
        let mirror = MirrorSet {
            local: vec![(v4("192.168.1.1"), 1)],
            connected: vec![(v4("192.168.1.0"), 24, 6)],
        };
        let ts = vec![
            target(1, "wan1", "eth1", "10.0.0.1"),
            target(2, "wan2", "eth2", "10.1.0.1"),
        ];
        let d = plan(&ts, &mirror, &[Family::V4]).unwrap();
        // 2 条默认路由 + 2 张表各 2 条镜像 = 6
        assert_eq!(d.routes.len(), 6);
        assert_eq!(d.routes.iter().filter(|r| r.kind == RTN_LOCAL).count(), 2);
        assert!(!d
            .routes
            .iter()
            .any(|r| r.dst_len == 0 && r.kind == RTN_LOCAL));
    }

    #[test]
    fn rollback_restores_previously_deleted_rules() {
        // 回滚不是「清空」：被我们删掉的旧规则必须装回去，否则失败的 apply
        // 会把本来正常工作的线路一起弄挂。
        let fake = FakeNetlink::default();
        let old = RuleSpec {
            family: Family::V4,
            priority: prio_for_slot(1),
            table: 101,
            fwmark: 1,
            fwmask: 0xff,
        };
        fake.add_rule(&old).unwrap();
        fake.fail_add_rule
            .lock()
            .unwrap()
            .push(Some("EPERM：权限不足".into()));
        let new = RuleSpec {
            family: Family::V4,
            priority: prio_for_slot(2),
            table: 102,
            fwmark: 2,
            fwmask: 0xff,
        };
        let diff = Diff {
            del_rules: vec![old.clone()],
            add_rules: vec![new.clone()],
            ..Diff::default()
        };
        let ap = Applier::new(&fake);
        assert!(ap.apply(&diff).is_err());
        let now = fake.dump_rules(Family::V4).unwrap();
        assert!(
            now.iter().any(|r| r.priority == old.priority),
            "旧规则要恢复"
        );
        assert!(
            !now.iter().any(|r| r.priority == new.priority),
            "半成品新规则要清掉"
        );
    }

    #[test]
    fn rollback_failures_are_surfaced_not_swallowed() {
        // 第二个 add 失败 → 回滚删第一个；若回滚删除也失败，必须把遗留问题写进错误。
        let fake = FakeNetlink::default();
        let a = RuleSpec {
            family: Family::V4,
            priority: prio_for_slot(1),
            table: 101,
            fwmark: 1,
            fwmask: 0xff,
        };
        let b = RuleSpec {
            family: Family::V4,
            priority: prio_for_slot(2),
            table: 102,
            fwmark: 2,
            fwmask: 0xff,
        };
        fake.fail_add_rule
            .lock()
            .unwrap()
            .extend([None, Some("ENOBUFS".into())]);
        fake.fail_del_rule
            .lock()
            .unwrap()
            .push(Some("EPERM".into()));
        let diff = Diff {
            add_rules: vec![a.clone(), b],
            ..Diff::default()
        };
        let err = Applier::new(&fake).apply(&diff).unwrap_err();
        assert!(
            matches!(err, Error::Rollback(_)),
            "回滚有遗留问题时应报 Rollback，实际 {err:?}"
        );
        assert!(err.to_string().contains("遗留问题"));
        // 空 diff 不应触碰内核
        assert!(Applier::new(&FakeNetlink::default())
            .apply(&Diff::default())
            .unwrap()
            .is_empty());
        assert_eq!(a.priority, prio_for_slot(1));
    }

    #[test]
    fn audit_detects_duplicate_priority_and_foreign_mark() {
        let mut a = our_rule(1, Family::V4);
        let b = our_rule(1, Family::V4);
        a.iifname = Some("br-lan".into());
        let issues = audit_conflicts(&[a.clone(), b], true, Family::V4);
        assert!(issues.iter().any(|i| i.message.contains("同优先级")));

        let foreign = RuleEntry {
            priority: prio_for_slot(5),
            table: 99,
            fwmark: Some(5),
            fwmask: Some(0xffffffff),
            ..our_rule(5, Family::V4)
        };
        let issues2 = audit_conflicts(&[foreign], true, Family::V4);
        assert_eq!(issues2[0].severity, Severity::Error);
        assert!(issues2[0].message.contains("他人安装的 fwmark 规则"));

        // main 表没有默认路由
        let issues3 = audit_conflicts(&[], false, Family::V6);
        assert!(issues3.iter().any(|i| i.path == "route.main.ipv6"));
    }

    #[test]
    fn plan_without_gateway_installs_nothing() {
        let mut t = target(1, "wan1", "eth1", "10.0.0.1");
        t.gw4 = None;
        t.gw6 = None;
        t.link_default = false;
        let d = plan(&[t], &MirrorSet::default(), &[Family::V4, Family::V6]).unwrap();
        assert!(
            d.rules.is_empty() && d.routes.is_empty(),
            "无网关不得留下指向空表的规则"
        );
    }

    #[test]
    fn plan_uses_link_scoped_default_for_p2p_wan() {
        // 5G 点对点链路：没有网关，只有 default dev wwan0 scope link
        let mut t = target(1, "wan_5g", "wwan0", "10.0.0.1");
        t.gw4 = None;
        t.link_default = true;
        let want = t.clone();
        let d = plan(&[t], &MirrorSet::default(), &[Family::V4]).unwrap();
        assert_eq!(d.rules.len(), 1, "链路级默认路由同样是可用出口");
        assert_eq!(d.routes.len(), 1);
        let r = &d.routes[0];
        assert_eq!(r.gateway, None, "不能给点对点链路编造网关");
        assert_eq!(r.oif, Some(want.ifindex));
        assert_eq!(r.dst, None);
        assert_eq!(r.dst_len, 0);
        assert!(want.usable_v4() && !want.usable_v6());
    }
}
