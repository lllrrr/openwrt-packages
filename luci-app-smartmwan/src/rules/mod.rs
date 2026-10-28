//! 规则层：把 UCI 里的游戏/客户端规则编译成 [`GameSpec`]。
//!
//! 位置：`config`（用户写了什么）→ **`rules`（这些条件在数据面上到底意味着什么）** →
//! `system::firewall`（怎么写成 nft 脚本）。三层各管一件事，规则层不生成任何 nft 文本，
//! 否则「匹配范围」与「语法兼容性」两件事会互相掩盖。
//!
//! # 合并语义（预置项 + 自定义）
//!
//! 明确定义，避免实现随手并一下：
//!
//! | 字段 | 语义 | 理由 |
//! |---|---|---|
//! | 目的网段 | **并集** | 预置项给服务器段，用户加自己的段，两者都要生效 |
//! | 域名 | **并集** | 同上 |
//! | 端口 | 规则写了就用规则的，没写才用预置项的 | 端口是「这条规则放行哪些端口」；把预置项的整段端口范围并进来会静默扩大匹配面 |
//! | 协议 | 规则不是 `both` 就用规则的，否则用预置项的 | 同上 |
//! | 客户端 IP/MAC | 只用规则的 | 预置项描述服务器，不该规定「哪些主机」 |
//!
//! # 不生成规则的情形（都会留一条可显示的说明）
//!
//! * 规则停用；
//! * `selection = follow`（跟随普通策略 ⇒ 本来就不该有独立标记）；
//! * 全局模式为「主备」且 `game_policy = follow`（待命线路不允许被游戏流量使用）；
//! * `selection = best` 但本轮还没有择优结果（尚未完成首轮探测）——
//!   这时**不下发**而不是「先随便指一条」，否则界面显示的择优结论就成了编造。

use std::collections::BTreeMap;

use crate::config::schema::{Config, GamePolicy, GameSelection, Mode, ProtoFilter};
use crate::config::validate::{Issue, Severity};
use crate::rules::presets::Preset;
use crate::system::firewall::{
    Capabilities, GameSpec, RuleInfo, DYNAMIC_SET_SIZE, MAX_SET_ELEMENTS,
};
use crate::{marks, Error, Result};

pub mod dns_sets;
pub mod matchers;
pub mod presets;

/// 一条规则最多能有多少条客户端条件（与目的条件分开算，避免一侧吃掉另一侧的额度）。
const MAX_CLIENT_ELEMENTS: usize = 512;

/// 编译输入。
#[derive(Debug, Clone)]
pub struct Input<'a> {
    pub cfg: &'a Config,
    /// 线路名 → 槽位（来自 `system::assign_slots`，必须由调用方提供，规则层不自建）。
    pub slots: &'a BTreeMap<String, u8>,
    /// 标记里的代际，与普通流量保持同一份，便于观测对齐。
    pub gen: u8,
    pub caps: &'a Capabilities,
    /// 已加载的预置项（磁盘上的数据文件）。
    pub presets: &'a [Preset],
    /// 择优结果：规则名 → 选定槽位。缺失表示本轮还没有结论。
    pub picks: &'a BTreeMap<String, u8>,
}

/// 编译产物。
#[derive(Debug, Clone, Default)]
pub struct Compiled {
    /// 交给 `firewall::Input::games`，已按 `(priority, name)` 排序。
    pub specs: Vec<GameSpec>,
    /// 面向用户的问题（Error 会让调用方放弃本轮，Warning/Info 只是说明）。
    pub issues: Vec<Issue>,
    /// 本轮需要解析的域名（已去重排序）。解析由守护进程在独立任务里做。
    pub domains: Vec<String>,
    /// 因「还没有择优结论」而暂未下发的规则名。
    pub pending: Vec<String>,
}

// ==================== 命中统计 ====================

/// 游戏规则的命中计数：**读到什么就是什么**，不推算、不补零、不把「读不到」当 0。
///
/// 数据源是内核里 `smw:game:<slug>` 规则的 `counter`（`firewall::build()` 给每条游戏
/// 规则都带了 `counter`）。一条 UCI 规则在数据面上可能对应**多条** nft 规则
/// （按地址族拆、按目的条件拆），所以对外按 slug **求和**。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GameHits {
    /// slug → (packets, bytes)。
    pub per_rule: BTreeMap<String, (u64, u64)>,
    /// 采样时刻（unix 毫秒）；`0` 表示从未采样成功。
    pub at_ms: u64,
    /// 没有数据时的原因。UI 必须原样显示 —— 0 与「读不到」是两回事。
    pub note: String,
}

impl GameHits {
    /// 一次链列表采样。
    ///
    /// 只认 `smw:game:` 前缀：桶规则、保护源、绕行目的都有自己的标签，
    /// 混进来会让「命中数」变成「链上全部新建连接」，那是另一个量。
    pub fn from_listing(rules: &[RuleInfo], now_ms: u64) -> GameHits {
        let mut per_rule: BTreeMap<String, (u64, u64)> = BTreeMap::new();
        for r in rules {
            let Some(c) = r.comment.as_deref() else {
                continue;
            };
            let Some(slug) = c.strip_prefix(GAME_TAG_PREFIX) else {
                continue;
            };
            let e = per_rule.entry(slug.to_string()).or_insert((0, 0));
            e.0 = e.0.saturating_add(r.packets);
            e.1 = e.1.saturating_add(r.bytes);
        }
        let note = if !per_rule.is_empty() {
            String::new()
        } else if rules.is_empty() {
            "链列表为空：没有读到任何规则（表/链不存在，或读取失败）".to_string()
        } else {
            "链上没有带 smw:game: 标签的规则：当前没有下发任何游戏规则".to_string()
        };
        GameHits {
            per_rule,
            at_ms: now_ms,
            note,
        }
    }

    /// 某条规则的命中数。**查不到返回 `None`** —— 调用方要显示「—」，
    /// 不能显示 0（0 会被读成「规则没命中过」，而真相可能是根本没读到）。
    pub fn of(&self, slug: &str) -> Option<(u64, u64)> {
        self.per_rule.get(slug).copied()
    }
}

/// 游戏规则标签前缀（与 `firewall::build()` 里生成的 `smw:game:<slug>` 一致）。
pub const GAME_TAG_PREFIX: &str = "smw:game:";

fn issue(sev: Severity, path: String, message: String, hint: Option<String>) -> Issue {
    Issue {
        severity: sev,
        path,
        message,
        hint,
    }
}

/// 编译全部启用的规则。
///
/// 错误（`Err`）只用于「无法安全继续」的情况：槽位指向不存在的线路、
/// 引用了不存在的预置项、条目数量超上限、非法 CIDR/端口/MAC。
/// 业务上的「这条规则本轮不生效」走 `issues`/`pending`，不是错误 ——
/// 一条停用的规则不该让整轮下发失败。
pub fn compile(input: &Input<'_>) -> Result<Compiled> {
    let mut out = Compiled::default();
    let cfg = input.cfg;

    // 排序：数值小者优先，同值按名称字典序。`config::decode` 已经这样排过，
    // 这里再排一次，保证直接构造 `Config`（测试、RPC 试算）时同样确定。
    let mut rules: Vec<_> = cfg.games.clone();
    rules.sort_by(|a, b| {
        a.priority
            .cmp(&b.priority)
            .then_with(|| a.name.cmp(&b.name))
    });

    let failover_follow =
        matches!(cfg.global.mode, Mode::Failover) && cfg.global.game_policy == GamePolicy::Follow;

    // slug 必须在「哪些规则本轮下发」之前就固定：若只在通过状态过滤的规则上分配，
    // 一条 pending / follow 规则恢复下发时会让排在其后的规则整体改名 —— nft 标签随之变化，
    // 内核 counter 归零、命中数错位。因此先对**全部**规则按同一排序分配，再逐条过滤。
    let slugs = game_slugs(&cfg.games);
    debug_assert_eq!(
        slugs.len(),
        rules.len(),
        "slug 分配必须与排序后的规则一一对应"
    );

    for (r, (_, slug)) in rules.iter().zip(slugs.iter()) {
        let path = format!("smartmwan.game[{}]", r.name);
        if !r.enabled {
            out.issues.push(issue(
                Severity::Info,
                path.clone(),
                "规则已停用，未下发任何数据面对象".into(),
                None,
            ));
            continue;
        }
        if r.selection == GameSelection::Follow {
            out.issues.push(issue(
                Severity::Info,
                path.clone(),
                "选路方式为 follow：该规则不改标记，流量按普通策略分配".into(),
                None,
            ));
            continue;
        }
        if failover_follow {
            // 主备模式 + 不允许游戏例外：待命线路根本不承载流量，
            // 下发规则只会让界面显示一条「生效」却永远不改变出口的规则。
            out.issues.push(issue(
                Severity::Info,
                path.clone(),
                "当前为主备模式且游戏策略为 follow，游戏规则暂不下发".into(),
                Some("需要游戏流量走待命线路时，把全局 game_policy 设为 exception".into()),
            ));
            continue;
        }

        // ---- 预置项合并（语义见模块头表格）----
        let preset: Option<&Preset> = if r.preset.trim().is_empty() {
            None
        } else {
            Some(
                input
                    .presets
                    .iter()
                    .find(|p| p.id == r.preset.trim())
                    .ok_or_else(|| {
                        Error::Config(format!(
                            "规则 {} 引用了不存在的预置项 {}（预置项目录里没有，或 id 拼错）",
                            r.name, r.preset
                        ))
                    })?,
            )
        };
        // 目的网段：预置项 ∪ 规则自定义；域名：预置项 ∪ 规则自定义。
        let (dst, ports, preset_domains) = match preset {
            None => (
                matchers::split_normalize(&r.targets, "目的网段")?,
                matchers::normalize_ports(&r.ports)?,
                Vec::new(),
            ),
            Some(p) => {
                let (a, pp, dd) = presets::expanded(p, &r.targets)?;
                let ports = if r.ports.is_empty() {
                    pp
                } else {
                    matchers::normalize_ports(&r.ports)?
                };
                (a, ports, dd)
            }
        };
        let mut domains = preset_domains;
        for d in matchers::normalize_domains(&r.domains)? {
            if !domains.contains(&d) {
                domains.push(d);
            }
        }
        domains.sort();
        let preset_proto = preset.map(|p| p.proto);

        // 规则自己的域名与预置项域名取并集。
        if !r.domains.is_empty() {
            let extra = matchers::normalize_domains(&r.domains)?;
            for d in extra {
                if !domains.contains(&d) {
                    domains.push(d);
                }
            }
            domains.sort();
        }

        let cli = matchers::split_normalize(&r.client_ips, "客户端地址")?;
        let macs = matchers::normalize_macs(&r.client_macs)?;
        dns_sets::Registry::check_domain_budget(&domains)?;

        // ---- 选路 ----
        let slot: u8 = match r.selection {
            GameSelection::Pin => {
                if r.pin_wan.trim().is_empty() {
                    return Err(Error::Config(format!(
                        "规则 {} 为 pin 但未指定 pin_wan",
                        r.name
                    )));
                }
                match input.slots.get(&r.pin_wan) {
                    Some(s) => *s,
                    None => {
                        return Err(Error::Config(format!(
                            "规则 {} 固定到线路 {}，但该线路未启用或不存在（槽位表里没有它）",
                            r.name, r.pin_wan
                        )))
                    }
                }
            }
            GameSelection::Best => match input.picks.get(&r.name) {
                Some(s) => *s,
                None => {
                    // 关键：没有择优结果时不下发，而不是随便挑一条线路。
                    out.pending.push(r.name.clone());
                    out.issues.push(issue(
                        Severity::Info,
                        path.clone(),
                        "本轮尚无质量择优结果（首轮探测未完成），该规则暂未下发".into(),
                        Some("探测完成后会自动生效，无需手工干预".into()),
                    ));
                    continue;
                }
            },
            GameSelection::Follow => continue, // 上面已处理
        };
        if slot == 0 || slot > marks::MAX_WANS {
            return Err(Error::Config(format!(
                "规则 {} 的槽位 {slot} 非法（有效范围 1..={}）",
                r.name,
                marks::MAX_WANS
            )));
        }

        // ---- 数量上限：超了必须报错，不能截断 ----
        // 截断 = 静默少拦网段，属于「看起来生效但其实不是」；报错则一定会被看到。
        for (kind, n) in [
            ("目的网段(IPv4)", dst.v4.len()),
            ("目的网段(IPv6)", dst.v6.len()),
            ("客户端地址", cli.len() + macs.len()),
        ] {
            let cap = if kind.starts_with("客户端") {
                MAX_CLIENT_ELEMENTS
            } else {
                MAX_SET_ELEMENTS
            };
            if n > cap {
                return Err(Error::Config(format!(
                    "规则 {} 的{kind}有 {n} 条，超过上限 {cap}",
                    r.name
                )));
            }
        }

        let mark = marks::mark(slot, marks::CLASS_GAME, input.gen, 0);
        if mark == 0 {
            return Err(Error::Config(format!("规则 {} 算出的标记为 0", r.name)));
        }

        // 有域名但没有动态集合能力：集合名照样给出，由 `firewall` 报「能力不支持」并
        // 放弃该族规则。这里不提前吞掉，是为了让降级只在一个地方（语法层）决定。
        let has_dst = !dst.is_empty() || !domains.is_empty();
        if !has_dst && cli.is_empty() && macs.is_empty() {
            return Err(Error::Config(format!(
                "规则 {} 没有任何条件：这会命中 LAN 内全部新建连接，请把规则改成至少有一个目的或客户端条件",
                r.name
            )));
        }

        let dns_set = if domains.is_empty() {
            None
        } else {
            // 集合名固定 `smw_g_<slug>_dns`，与 firewall 侧的 `smw_g_<slug>_{dst,cli}` 同构。
            Some(format!("smw_g_{slug}_dns"))
        };
        out.specs.push(GameSpec {
            name: r.name.clone(),
            slug: slug.clone(),
            priority: r.priority,
            mark,
            v4: dst.v4.clone(),
            v6: dst.v6.clone(),
            macs,
            client_v4: cli.v4.clone(),
            client_v6: cli.v6.clone(),
            ports,
            proto: effective_proto(r, preset_proto),
            dns_set,
            dns_timeout_s: cfg.global.dns_ttl_floor_s,
        });
        if !domains.is_empty() {
            out.domains.extend(domains.iter().cloned());
        }
        if let Some(p) = preset {
            out.issues.push(issue(
                Severity::Info,
                path.clone(),
                format!("规则 {} 使用预置项 {}（来源：{}）", r.name, p.id, p.source),
                None,
            ));
        }
    }

    out.domains.sort();
    out.domains.dedup();
    // 集合规模上限的一致性检查：域名解析出来的元素进的是 `DYNAMIC_SET_SIZE` 的动态集合。
    if out.domains.len() > DYNAMIC_SET_SIZE as usize {
        return Err(Error::Config(format!(
            "本轮待解析域名 {} 个，超过动态集合容量 {}",
            out.domains.len(),
            DYNAMIC_SET_SIZE
        )));
    }
    Ok(out)
}

/// 按 `compile()` 的排序与消歧规则，为**全部**规则算出稳定 slug（顺序同为排序后顺序）。
///
/// 供 `compile()` 与 RPC 展示共用：两处若各算一套，中文名（slug 为空）或同 slug 冲突时，
/// 界面显示的 slug 与实际下发的 nft 标签就对不上 —— 命中数会显示成「—」或记到别的规则头上。
pub fn game_slugs(games: &[crate::config::schema::GameRule]) -> Vec<(String, String)> {
    let mut sorted: Vec<&crate::config::schema::GameRule> = games.iter().collect();
    sorted.sort_by(|a, b| {
        a.priority
            .cmp(&b.priority)
            .then_with(|| a.name.cmp(&b.name))
    });
    let mut used: BTreeMap<String, u32> = BTreeMap::new();
    sorted
        .into_iter()
        .map(|r| {
            (
                r.name.clone(),
                unique_slug(&mut used, &matchers::slug_of(&r.name)),
            )
        })
        .collect()
}

/// 规则与预置项的协议取法（见模块头的合并语义表）。
fn effective_proto(
    r: &crate::config::schema::GameRule,
    preset_proto: Option<ProtoFilter>,
) -> ProtoFilter {
    if r.proto != ProtoFilter::Both {
        r.proto
    } else {
        preset_proto.unwrap_or(r.proto)
    }
}

/// 生成唯一的 nft 对象名后缀。
///
/// 冲突时必须**确定性地**改名，而不是报错：两条规则一个中文名（slug 为空）
/// 或两个 ASCII 名清洗后撞车（`PUBG EU` / `pubg-eu`）都很常见，
/// 直接报错会让用户看到一条和「重名」毫无关系的失败信息。
/// 后缀按出现顺序 `-2`、`-3`，而出现顺序由 `(priority, name)` 决定 ⇒ 可复现。
fn unique_slug(used: &mut BTreeMap<String, u32>, base: &str) -> String {
    let base = if base.is_empty() { "rule" } else { base };
    let n = used.entry(base.to_string()).or_insert(0);
    *n += 1;
    if *n == 1 {
        base.to_string()
    } else {
        // 3 字节后缀：`base` 最长 24，加上 `-12` 仍在 `firewall::safe_name` 的 40 以内。
        format!("{base}-{}", *n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::{GameRule, GlobalConfig, WanConfig};
    use crate::system::firewall::Capabilities;

    fn wan(name: &str) -> WanConfig {
        WanConfig {
            name: name.into(),
            enabled: true,
            ..Default::default()
        }
    }

    fn cfg(games: Vec<GameRule>) -> Config {
        Config {
            global: GlobalConfig {
                enabled: true,
                ..Default::default()
            },
            wans: vec![wan("wan1"), wan("wan2"), wan("wan3")],
            games,
            score: Default::default(),
        }
    }

    fn slots() -> BTreeMap<String, u8> {
        let mut m = BTreeMap::new();
        m.insert("wan1".into(), 1);
        m.insert("wan2".into(), 2);
        m.insert("wan3".into(), 3);
        m
    }

    fn rule(name: &str) -> GameRule {
        GameRule {
            name: name.into(),
            enabled: true,
            priority: 10,
            preset: String::new(),
            targets: vec!["203.0.113.0/24".into()],
            ports: vec!["30000-30100".into()],
            proto: ProtoFilter::Udp,
            client_ips: vec!["192.168.1.20".into()],
            client_macs: vec![],
            domains: vec![],
            selection: GameSelection::Pin,
            pin_wan: "wan2".into(),
            comment: String::new(),
        }
    }

    fn compile_with(c: &Config, picks: &BTreeMap<String, u8>) -> Result<Compiled> {
        let s = slots();
        let inp = Input {
            cfg: c,
            slots: &s,
            gen: 3,
            caps: &Capabilities::default(),
            presets: &[],
            picks,
        };
        compile(&inp)
    }

    #[test]
    fn pin_produces_game_mark() {
        let c = cfg(vec![rule("demo")]);
        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        assert_eq!(out.specs.len(), 1);
        let g = &out.specs[0];
        assert_eq!(g.slug, "demo");
        assert_eq!(marks::slot_of(g.mark), 2, "pin 到 wan2 ⇒ 槽位 2");
        assert_eq!(
            g.mark & marks::CLASS_MASK,
            marks::CLASS_GAME << marks::CLASS_SHIFT
        );
        assert_eq!(marks::gen_of(g.mark), 3);
        assert_eq!(g.v4, vec!["203.0.113.0/24".to_string()]);
        assert_eq!(g.client_v4, vec!["192.168.1.20/32".to_string()]);
        assert_eq!(g.ports, vec!["30000-30100".to_string()]);
        assert!(g.dns_set.is_none());
    }

    #[test]
    fn follow_and_disabled_are_not_emitted() {
        let mut a = rule("followed");
        a.selection = GameSelection::Follow;
        let mut b = rule("off");
        b.enabled = false;
        let c = cfg(vec![a, b]);
        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        assert!(out.specs.is_empty());
        assert_eq!(out.issues.len(), 2);
        assert!(out.issues.iter().all(|i| i.severity == Severity::Info));
    }

    #[test]
    fn best_without_pick_is_pending_not_fabricated() {
        // 这是「绝不把编造当结论」的规则层版本：没有择优结果 ⇒ 不下发、进 pending。
        let mut r = rule("needbest");
        r.selection = GameSelection::Best;
        r.pin_wan.clear();
        let c = cfg(vec![r]);
        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        assert!(out.specs.is_empty(), "没有择优结论时不能随便挑一条线路");
        assert_eq!(out.pending, vec!["needbest".to_string()]);
        let mut picks = BTreeMap::new();
        picks.insert("needbest".to_string(), 3u8);
        let out2 = compile_with(&c, &picks).unwrap();
        assert_eq!(marks::slot_of(out2.specs[0].mark), 3, "有结论后按结论下发");
    }

    #[test]
    fn slug_is_stable_when_an_earlier_rule_is_pending() {
        // "demo 1"（best，本轮无结论 ⇒ pending）排在 "demo-1" 前面，二者 slug_of 都是
        // demo_1。若只在「本轮下发」的规则上分配 slug，pending 那条恢复下发时会把
        // demo-1 改名成 demo_1-2 —— nft 标签随之变化，内核 counter 归零、命中数错位。
        let mut pending = rule("demo 1");
        pending.selection = GameSelection::Best;
        pending.pin_wan.clear();
        let c = cfg(vec![pending, rule("demo-1")]);

        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        assert_eq!(out.pending, vec!["demo 1".to_string()]);
        assert_eq!(out.specs.len(), 1);
        assert_eq!(out.specs[0].slug, "demo_1-2", "pending 在前也占住 demo_1");

        // 择优结论到达后，先前已下发的那条 slug 必须保持不变。
        let mut picks = BTreeMap::new();
        picks.insert("demo 1".to_string(), 3u8);
        let out2 = compile_with(&c, &picks).unwrap();
        assert_eq!(out2.specs.len(), 2);
        assert_eq!(out2.specs[0].slug, "demo_1");
        assert_eq!(out2.specs[1].slug, "demo_1-2");
    }

    #[test]
    fn game_slugs_matches_the_slugs_compile_actually_emits() {
        // RPC 展示与 compile 共用同一套消歧：否则界面显示的 slug 与内核标签对不上。
        let c = cfg(vec![rule("PUBG EU"), rule("pubg-eu"), rule("游戏")]);
        let map: BTreeMap<String, String> = game_slugs(&c.games).into_iter().collect();
        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        for g in &out.specs {
            assert_eq!(map.get(&g.name), Some(&g.slug), "{}", g.name);
        }
        assert_eq!(map.get("PUBG EU").map(String::as_str), Some("pubg_eu"));
        assert_eq!(map.get("pubg-eu").map(String::as_str), Some("pubg_eu-2"));
        // 纯中文名 slug 为空，兜底为 rule（仍按排序确定）。
        assert_eq!(map.get("游戏").map(String::as_str), Some("rule"));
    }

    #[test]
    fn failover_follow_blocks_game_rules() {
        let mut g = GlobalConfig {
            enabled: true,
            mode: Mode::Failover,
            game_policy: GamePolicy::Follow,
            ..Default::default()
        };
        let mut c = cfg(vec![rule("x")]);
        g.enabled = true;
        c.global = g;
        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        assert!(out.specs.is_empty());
        assert!(out.issues[0].message.contains("主备"), "{:?}", out.issues);
    }

    #[test]
    fn pin_to_missing_line_is_error() {
        let mut r = rule("bad");
        r.pin_wan = "wan9".into();
        let c = cfg(vec![r]);
        let e = compile_with(&c, &BTreeMap::new()).unwrap_err().to_string();
        assert!(e.contains("未启用或不存在"), "{e}");
    }

    #[test]
    fn pin_without_target_needs_client_condition() {
        // 全条件为空 ⇒ 命中 LAN 全部新建连接，必须拒绝。
        let mut r = rule("wide");
        r.targets.clear();
        r.client_ips.clear();
        let c = cfg(vec![r]);
        assert!(compile_with(&c, &BTreeMap::new()).is_err());
        // 只有客户端条件时是「这批主机的全部新建连接」，允许（firewall 层会给出 Info 说明）。
        let mut r2 = rule("hosts");
        r2.targets.clear();
        r2.client_macs = vec!["AA:BB:CC:DD:EE:FF".into()];
        let c2 = cfg(vec![r2]);
        let out = compile_with(&c2, &BTreeMap::new()).unwrap();
        assert_eq!(out.specs[0].macs, vec!["aa:bb:cc:dd:ee:ff".to_string()]);
    }

    #[test]
    fn slug_collisions_are_deterministic() {
        let mut a = rule("PUBG EU");
        a.priority = 5;
        let mut b = rule("pubg-eu"); // 清洗后与 a 同名
        b.priority = 6;
        let mut c = rule("绝地求生"); // slug 为空 ⇒ base "rule"
        c.priority = 7;
        let mut d = rule("英雄联盟"); // 同样 base "rule"
        d.priority = 8;
        let cc = cfg(vec![b.clone(), a.clone(), d.clone(), c.clone()]);
        let out = compile_with(&cc, &BTreeMap::new()).unwrap();
        let slugs: Vec<&str> = out.specs.iter().map(|g| g.slug.as_str()).collect();
        // 排序按 priority：5(pubg_eu) 6(pubg_eu-2) 7(rule) 8(rule-2)
        assert_eq!(slugs, vec!["pubg_eu", "pubg_eu-2", "rule", "rule-2"]);
        // 同一输入再编译一次，结果必须逐字节一致（可复现性）。
        let out2 = compile_with(&cc, &BTreeMap::new()).unwrap();
        assert_eq!(out.specs, out2.specs);
    }

    #[test]
    fn domains_become_dns_set_and_are_listed() {
        let mut r = rule("domained");
        r.targets.clear();
        r.domains = vec!["A.Example.".into(), "a.example".into(), "b.example".into()];
        let c = cfg(vec![r]);
        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        assert_eq!(out.specs[0].dns_set.as_deref(), Some("smw_g_domained_dns"));
        assert_eq!(out.specs[0].dns_timeout_s, 300);
        assert_eq!(
            out.domains,
            vec!["a.example".to_string(), "b.example".to_string()]
        );
    }

    #[test]
    fn preset_union_and_port_override() {
        let p = Preset {
            id: "demo".into(),
            label: "示例".into(),
            source: "管理员核对".into(),
            updated: String::new(),
            targets: vec!["198.51.100.0/24".into()],
            ports: vec!["20000-20010".into()],
            proto: ProtoFilter::Both,
            domains: vec!["srv.example".into()],
        };
        let mut r = rule("withpreset");
        r.preset = "demo".into();
        r.targets = vec!["203.0.113.0/24".into()];
        r.ports = vec!["30000".into()]; // 规则写了端口 ⇒ 不用预置项的
        let c = cfg(vec![r]);
        let s = slots();
        let inp = Input {
            cfg: &c,
            slots: &s,
            gen: 1,
            caps: &Capabilities::default(),
            presets: std::slice::from_ref(&p),
            picks: &BTreeMap::new(),
        };
        let out = compile(&inp).unwrap();
        let g = &out.specs[0];
        assert_eq!(
            g.v4,
            vec!["198.51.100.0/24".to_string(), "203.0.113.0/24".to_string()],
            "目的网段取并集"
        );
        assert_eq!(g.ports, vec!["30000".to_string()], "端口以规则为准");
        assert_eq!(g.dns_set.as_deref(), Some("smw_g_withpreset_dns"));
        assert_eq!(out.domains, vec!["srv.example".to_string()]);
        assert!(out.issues.iter().any(|i| i.message.contains("来源")));

        // 规则没写端口时才继承预置项端口。
        let mut r2 = rule("inheritports");
        r2.preset = "demo".into();
        r2.ports.clear();
        let c2 = cfg(vec![r2]);
        let out2 = compile(&Input {
            cfg: &c2,
            slots: &s,
            gen: 1,
            caps: &Capabilities::default(),
            presets: std::slice::from_ref(&p),
            picks: &BTreeMap::new(),
        })
        .unwrap();
        assert_eq!(out2.specs[0].ports, vec!["20000-20010".to_string()]);
    }

    #[test]
    fn unknown_preset_is_error() {
        let mut r = rule("ghost");
        r.preset = "not-there".into();
        let c = cfg(vec![r]);
        assert!(compile_with(&c, &BTreeMap::new())
            .unwrap_err()
            .to_string()
            .contains("不存在的预置项"));
    }

    #[test]
    fn proto_falls_back_to_preset_only_when_rule_is_both() {
        let mut r = rule("p");
        r.proto = ProtoFilter::Both;
        assert_eq!(
            effective_proto(&r, Some(ProtoFilter::Tcp)),
            ProtoFilter::Tcp,
            "规则没表态时用预置项的协议"
        );
        r.proto = ProtoFilter::Udp;
        assert_eq!(
            effective_proto(&r, Some(ProtoFilter::Tcp)),
            ProtoFilter::Udp
        );
    }

    #[test]
    fn oversized_rule_errors_instead_of_truncating() {
        // 生成大量条目必须报错，不能悄悄截断（截断＝少拦了网段还说生效）。
        let many: Vec<String> = (0..(MAX_SET_ELEMENTS + 1))
            .map(|i| format!("10.{}.{}.0/32", i / 256 % 256, i % 256))
            .collect();
        let mut r = rule("huge");
        r.targets = many;
        let c = cfg(vec![r]);
        assert!(compile_with(&c, &BTreeMap::new())
            .unwrap_err()
            .to_string()
            .contains("超过上限"));
    }

    #[test]
    fn invalid_matcher_input_is_error_not_skip() {
        let mut r = rule("badcidr");
        r.targets = vec!["203.0.113.0/40".into()];
        let c = cfg(vec![r]);
        assert!(compile_with(&c, &BTreeMap::new()).is_err());
        let mut r2 = rule("badmac");
        r2.client_macs = vec!["zz".into()];
        let c2 = cfg(vec![r2]);
        assert!(compile_with(&c2, &BTreeMap::new()).is_err());
    }

    /// 端到端（沙箱内可达的最远一步）：规则层产物直接喂给 `firewall::build`，
    /// 证明两层的数据契约真的对得上，而不只是各自单测自洽。
    /// 沙箱没有 `nft` 二进制，所以这里验证到「生成的脚本文本」为止，
    /// 真机上还要加一层 `nft -c` 校验（见 docs/TESTING.md §4）。
    #[test]
    fn compiled_specs_are_accepted_by_firewall_build() {
        use crate::config::schema::Algorithm;
        use crate::system::firewall::{build, Input as FtInput, Line};
        use crate::system::netlink::Family;

        let mut r = rule("pubg_eu");
        r.client_macs = vec!["AA:BB:CC:DD:EE:FF".into()];
        r.domains = vec!["srv.example".into()];
        let c = cfg(vec![r]);
        let out = compile_with(&c, &BTreeMap::new()).unwrap();
        assert_eq!(out.specs.len(), 1);

        let lines: Vec<Line> = vec![
            Line {
                name: "wan1".into(),
                slot: 1,
            },
            Line {
                name: "wan2".into(),
                slot: 2,
            },
        ];
        let lan = vec!["br-lan".to_string()];
        let bucket_map: Vec<u8> = vec![2; usize::from(marks::BUCKETS)];
        // 能力用保守默认：`dyn_timeout_sets` 为 false，域名条件必须降级成一条明确警告，
        // 而不是悄悄留下一条匹配范围被放大的规则。
        let caps = Capabilities::default();
        let inp = FtInput {
            algorithm: Algorithm::SrcIpDstIp,
            buckets: marks::BUCKETS,
            bucket_map: &bucket_map,
            gen: 3,
            hash_seed: 0,
            conn_sticky: true,
            families: &[Family::V4],
            lan_ifaces: &lan,
            lines: &lines,
            games: &out.specs,
            protected_v4: &[],
            protected_v6: &[],
            bypass_v4: &[],
            bypass_v6: &[],
            caps: &caps,
        };
        let prog = build(&inp).expect("规则层产物必须能被 firewall 层接受");
        assert!(
            prog.text.contains("set smw_g_pubg_eu_dst4"),
            "{}",
            prog.text
        );
        assert!(prog.text.contains("set smw_g_pubg_eu_mac"));
        let game_rule = prog
            .text
            .lines()
            .find(|l| l.contains("smw:game:pubg_eu"))
            .expect("游戏规则应出现在 prerouting")
            .to_string();
        assert!(game_rule.contains("ether saddr @smw_g_pubg_eu_mac"));
        assert!(game_rule.contains("ip daddr @smw_g_pubg_eu_dst4"));
        assert!(game_rule.contains("ip saddr @smw_g_pubg_eu_cli4"));
        // 动态集合能力未验证 ⇒ 必须显式报告降级。
        assert!(
            prog.issues.iter().any(|i| i.message.contains("dynamic")),
            "域名集合能力缺失必须显式报告：{:?}",
            prog.issues
        );
    }

    fn listed(comment: Option<&str>, packets: u64, bytes: u64) -> RuleInfo {
        RuleInfo {
            handle: 1,
            comment: comment.map(str::to_string),
            body: String::new(),
            packets,
            bytes,
        }
    }

    #[test]
    fn hits_sum_every_nft_rule_of_one_uci_rule_and_ignore_the_rest() {
        // 一条 UCI 规则在数据面上可能是多条 nft 规则（按族/目的条件拆），要**求和**；
        // 桶规则与其它标签的计数不属于「游戏规则命中」，混进来会让数字变成全链流量。
        let listing = vec![
            listed(Some("smw:game:svc"), 10, 100),
            listed(Some("smw:game:svc"), 5, 50),
            listed(Some("smw:bucket:3"), 9999, 9999),
            listed(None, 7, 7),
        ];
        let h = GameHits::from_listing(&listing, 1000);
        assert_eq!(h.of("svc"), Some((15, 150)));
        assert_eq!(
            h.of("nope"),
            None,
            "查不到必须是 None，不能用 0 冒充「没命中过」"
        );
        assert_eq!(h.at_ms, 1000);
        assert!(h.note.is_empty());
    }

    #[test]
    fn hits_say_why_there_is_no_data_instead_of_returning_zero() {
        let empty = GameHits::from_listing(&[], 0);
        assert!(empty.of("svc").is_none());
        assert!(empty.note.contains("链列表为空"));

        let no_game_rules = vec![listed(Some("smw:bucket:1"), 3, 3)];
        let h = GameHits::from_listing(&no_game_rules, 5);
        assert!(h.note.contains("没有下发任何游戏规则"));
    }
}
