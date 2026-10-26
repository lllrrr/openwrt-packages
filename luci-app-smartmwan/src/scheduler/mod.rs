//! 调度器装配层：把「健康快照 + 负载采样 + 配置」翻译成数据面可以直接下发的桶图。
//!
//! # 为什么需要这一层
//!
//! [`balancing`]、[`failover`]、[`latency`] 各自只知道自己的那半件事，
//! 而数据面只认一个东西：`bucket -> slot` 的映射表。本模块负责
//!
//! * 从 [`Snapshot`] + 配置组装三个子模块需要的输入（线路状态、候选、评分）；
//! * 按 `global.mode` 决定走主备还是均衡，并把结果统一成 [`Outcome`]；
//! * 记住上一轮桶图，只有**真的变了**才报告 `changed` —— 这是「不做高频全量重建」
//!   在应用层的对应约束（`firewall` 层再配合 `replace rule handle`）。
//!
//! # 诚实原则
//!
//! * 首轮探测没完成 → 明确写进 `notes`，不假装线路健康。
//! * 算法不支持（加权 ECMP）→ 降级为加权哈希并把降级写进 `notes`，
//!   而不是让守护进程报错退出（服务不能因为一个下拉框选项崩掉）。
//! * 所有线路都不可用 → 桶图全 0，即「不标记、走系统默认路由」，
//!   UI 显示「无可用线路」。
//!
//! # 状态归属
//!
//! 本结构体是有状态的（当前活动线路、去抖进度、上一轮桶图），
//! 因此**只能由单个任务持有**（主循环），RPC 通过主循环转发的只读快照访问它。
//! 不提供内部 `Mutex`：并发调度会产生两个互相冲突的桶图，那是数据事故。

pub mod balancing;
pub mod failover;
pub mod hysteresis;
pub mod latency;

use std::collections::{BTreeMap, VecDeque};

use crate::config::schema::{Algorithm, Config, GamePolicy, Mode, WanRole};
use crate::health::{Snapshot, State};
use crate::{Error, Result};

use balancing::Load;
use failover::{LineState, Machine};
use latency::Scored;

/// 一轮调度产出的完整决策，可直接序列化给 RPC、也可用于生成 nftables 桶映射。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Outcome {
    /// 本轮工作模式。
    pub mode: Mode,
    /// 本轮实际生效的算法（与配置不同时说明发生了降级，见 `notes`）。
    pub algorithm: Algorithm,
    /// `bucket -> slot`；长度 = `global.buckets`，全 0 表示不分流。
    pub buckets: Vec<u8>,
    /// 相对上一轮是否真的变了：`false` 时数据面**不需要**任何写操作。
    pub changed: bool,
    /// 主备模式下的活动线路；均衡模式恒为 `None`。
    pub active: Option<String>,
    /// 待命线路（仅主备模式）。
    pub standby: Vec<String>,
    /// 正在等待回切的线路与还差的条件（仅主备模式）。
    pub waiting: Option<(String, String)>,
    /// 一条可用线路都没有。
    pub all_dead: bool,
    /// 决策依据（中文，可直接显示）。
    pub reason: String,
    /// 限制、降级、等待说明。UI 必须原样展示，不得只挑「好消息」。
    pub notes: Vec<String>,
    /// 每条线路实际分到的桶数（按桶数降序，展示真实比例）。
    pub share: Vec<(String, usize)>,
    /// 相对上一轮搬动了多少个桶。
    pub moved: usize,
    /// 本轮决策时间（unix 毫秒）。
    pub at_ms: u64,
}

impl Outcome {
    /// 是否有桶被分配出去（`false` = 此刻插件对数据面零影响）。
    pub fn carries_traffic(&self) -> bool {
        self.buckets.iter().any(|b| *b != 0)
    }

    /// 一行式说明，供日志与 `运行总览` 使用。
    pub fn explain(&self) -> String {
        let mut s = format!(
            "{}模式/{}：{}（{} 个桶）",
            self.mode.as_str(),
            self.algorithm.as_str(),
            self.reason,
            self.buckets.len()
        );
        if !self.share.is_empty() {
            let parts: Vec<String> = self.share.iter().map(|(n, c)| format!("{n}={c}")).collect();
            s.push_str("；分配 ");
            s.push_str(&parts.join(", "));
        }
        s
    }

    /// 桶数占比（千分比），UI 画条形图用；桶数为 0 时返回空而不是编造 0% 列表。
    pub fn share_permille(&self) -> Vec<(String, u32)> {
        let total = self.buckets.len();
        if total == 0 {
            return Vec::new();
        }
        self.share
            .iter()
            .map(|(n, c)| (n.clone(), (c * 1000 / total) as u32))
            .collect()
    }
}

/// 有状态的调度器。
pub struct Scheduler {
    failover: Machine,
    picker: latency::Picker,
    /// 上一轮下发的桶图（空 = 尚未下发过）。
    buckets: Vec<u8>,
    /// 上次桶图变化的时间，用于动态算法的最小重排间隔。
    last_rebalance_ms: u64,
    /// 最近的变更历史（有界）：RPC 的「最近事件」列表。
    history: VecDeque<(u64, String)>,
}

/// 历史条数上限：长跑进程不能无限增长。
const HISTORY_MAX: usize = 48;

impl Default for Scheduler {
    fn default() -> Self {
        Self::new()
    }
}

impl Scheduler {
    pub fn new() -> Scheduler {
        Scheduler {
            failover: Machine::new(),
            picker: latency::Picker::new(),
            buckets: Vec::new(),
            last_rebalance_ms: 0,
            history: VecDeque::new(),
        }
    }

    // ---------- 只读访问（RPC 用） ----------

    pub fn active(&self) -> Option<&str> {
        self.failover.active()
    }

    /// 主备顺序（供线路管理页画「主 / 备1 / 备2」）。
    pub fn failover_order(&self, cfg: &Config, snap: &Snapshot) -> Result<Vec<String>> {
        let slots = slot_map(cfg)?;
        Ok(failover::order(
            &cfg.global,
            &line_states(cfg, &slots, snap, crate::logging::now_ms()),
        ))
    }

    pub fn forced(&self) -> Option<&str> {
        self.failover.forced()
    }

    pub fn last_switch_ms(&self) -> u64 {
        self.failover.last_switch_ms()
    }

    pub fn buckets(&self) -> &[u8] {
        &self.buckets
    }

    pub fn history(&self) -> Vec<(u64, String)> {
        self.history.iter().cloned().collect()
    }

    pub fn picker(&self) -> &latency::Picker {
        &self.picker
    }

    /// 某条线路此刻的健康视图（供游戏选路页解释「为什么没选它」）。
    pub fn line_states(
        &self,
        cfg: &Config,
        snap: &Snapshot,
        now_ms: u64,
    ) -> Result<Vec<LineState>> {
        Ok(line_states(cfg, &slot_map(cfg)?, snap, now_ms))
    }

    // ---------- 写操作（RPC 强制切换 / 配置变更） ----------

    /// RPC：强制切换到某条线路（仅主备模式有意义）。
    ///
    /// 目标此刻不可用时**不报错也不丢弃指令**：`failover::Machine` 会等它可用后立刻生效，
    /// 这与「用户明确表达过的意志不能被静默吞掉」一致。
    pub fn force(&mut self, target: &str) {
        self.failover.force(target);
    }

    /// RPC：取消强制。
    pub fn release_forced(&mut self) {
        self.failover.release_forced();
    }

    /// 配置变更后复位：去抖计数与重排计时都带着旧配置的语义，不能续用。
    pub fn on_config_change(&mut self) {
        self.failover.reset_debounce();
        self.last_rebalance_ms = 0;
    }

    /// 游戏规则被删除/停用时清理其选路状态，避免长跑留下垃圾条目。
    pub fn forget_rule(&mut self, rule: &str) {
        self.picker.forget(rule);
    }

    // ---------- 主入口 ----------

    /// 计算本轮桶图。
    ///
    /// `loads` 只需提供**测量值**（连接数、速率、是否可信）；
    /// 上限类字段（带宽上限、单线路连接上限）在这里从配置补齐，
    /// 免得调用方各写一份而和 UI 显示的上限不一致。
    pub fn decide(
        &mut self,
        cfg: &Config,
        snap: &Snapshot,
        loads: &BTreeMap<String, Load>,
        now_ms: u64,
    ) -> Result<Outcome> {
        let slots = slot_map(cfg)?;
        let bucket_count = usize::from(cfg.global.buckets.max(1));
        // 停用配置：决策必须与数据面一致 —— 停用提交已把本插件的内核对象清空，
        // 决策不得再声称承载流量（真机实证：曾出现「内核已清场、UI 仍显示
        // 承载流量」的脱节）。停用期间全部流量走系统原路由（main 表）。
        if !cfg.global.enabled {
            // changed 只在「从有桶变为全零」的第一轮为真（触发一次停用清场提交）；
            // 内部桶状态必须同步归零，否则后续每轮都会误判 changed 再跑空事务。
            let changed =
                self.buckets.len() == bucket_count && self.buckets.iter().any(|b| *b != 0);
            self.buckets = vec![0; bucket_count];
            return Ok(Outcome {
                mode: cfg.global.mode,
                algorithm: cfg.global.algorithm,
                buckets: vec![0; bucket_count],
                changed,
                active: None,
                standby: Vec::new(),
                waiting: None,
                all_dead: false,
                reason: "插件已停用：全部流量走系统原路由（main 表），插件不接管".to_string(),
                notes: vec!["已停用：如需启用请先完成线路与健康探测配置".to_string()],
                share: Vec::new(),
                moved: 0,
                at_ms: now_ms,
            });
        }
        let lines = line_states(cfg, &slots, snap, now_ms);

        let mut notes: Vec<String> = Vec::new();
        if !snap.measured {
            notes.push(format!(
                "尚未完成首轮探测：本轮不把任何线路判为可用（探测周期 {}ms、超时 {}ms），\
                 页面在此期间必须显示「未测量」而不是 0ms",
                cfg.global.health.interval_ms, cfg.global.health.timeout_ms
            ));
        }
        let monitor: Vec<&str> = cfg
            .wans
            .iter()
            .filter(|w| w.enabled && w.role == WanRole::Monitor)
            .map(|w| w.name.as_str())
            .collect();
        if !monitor.is_empty() {
            notes.push(format!("仅探测线路不参与分流：{}", monitor.join("、")));
        }
        if let Some(m) = failover::missing_from_order(&cfg.global, &lines).first() {
            notes.push(format!(
                "线路 {m} 未出现在主备顺序中，已按槽位补齐（建议在界面上明确顺序）"
            ));
        }

        let (algorithm, active, standby, waiting, all_dead, reason, buckets, moved) = match cfg
            .global
            .mode
        {
            Mode::Failover => {
                let d = self.failover.decide(&cfg.global, &lines, now_ms);
                let map = d.bucket_map(&slots, bucket_count);
                let moved = count_moves(&self.buckets, &map);
                if let Some((n, why)) = &d.waiting {
                    notes.push(format!("等待回切 {n}：{why}"));
                }
                let st = d.standby(&lines);
                match cfg.global.game_policy {
                    GamePolicy::Follow => notes.push(
                        "游戏策略 follow：游戏流量与普通流量同走活动线路，待命线路不会承载任何流量"
                            .to_string(),
                    ),
                    GamePolicy::Exception => {
                        if st.is_empty() {
                            notes.push(
                                "游戏策略 exception（跨线路择优）已开启，但当前没有可用待命线路"
                                    .to_string(),
                            );
                        } else {
                            notes.push(format!(
                                "游戏策略 exception：{} 只可能被游戏白名单显式放行的流量使用，普通流量一律不走",
                                st.join("、")
                            ));
                        }
                    }
                }
                (
                    cfg.global.algorithm,
                    d.active,
                    st,
                    d.waiting,
                    d.all_dead,
                    d.reason,
                    map,
                    moved,
                )
            }
            Mode::Balance => {
                let cands = candidates(cfg, &slots, snap, loads);
                let interval_ok = hysteresis::interval_elapsed(
                    self.last_rebalance_ms,
                    now_ms,
                    cfg.global.rebalance_interval_ms,
                );
                let prev: Option<&[u8]> = if self.buckets.len() == bucket_count {
                    Some(&self.buckets)
                } else {
                    None
                };
                let req = balancing::Request {
                    algorithm: cfg.global.algorithm,
                    buckets: bucket_count,
                    candidates: &cands,
                    previous: prev,
                    smoothing_permille: cfg.global.smoothing_permille,
                    min_advantage_permille: cfg.score.min_advantage_permille,
                    interval_ok,
                };
                let mut used = cfg.global.algorithm;
                let a = match balancing::assign(&req) {
                    Ok(a) => a,
                    Err(Error::Unsupported(why)) => {
                        // 不支持的算法不能让服务退出：降级为加权哈希并如实说明。
                        notes.push(format!("算法降级：{why}"));
                        used = Algorithm::WeightedHash;
                        let mut r2 = req.clone();
                        r2.algorithm = Algorithm::WeightedHash;
                        balancing::assign(&r2)?
                    }
                    Err(e) => return Err(e),
                };
                notes.extend(a.notes.iter().cloned());
                if a.is_empty() {
                    notes.push(
                        "本轮没有任何桶被分配：流量走系统默认路由（main 表），插件不接管"
                            .to_string(),
                    );
                }
                (
                    used,
                    None,
                    Vec::new(),
                    None,
                    a.is_empty(),
                    a.reason.clone(),
                    a.buckets.clone(),
                    a.moved,
                )
            }
        };

        let changed = buckets != self.buckets;
        if changed {
            self.last_rebalance_ms = now_ms;
            self.push_history(now_ms, &format!("{}｜{reason}", cfg.global.mode.as_str()));
        }
        self.buckets = buckets.clone();

        Ok(Outcome {
            mode: cfg.global.mode,
            algorithm,
            buckets,
            changed,
            active,
            standby,
            waiting,
            all_dead,
            reason,
            notes,
            share: share_of(&self.buckets, &slots),
            moved,
            at_ms: now_ms,
        })
    }

    /// 游戏/低延迟候选排名（`rules` 层与 RPC 共用，保证界面与决策看到的是同一份分数）。
    ///
    /// * `snap` 里状态不是 HEALTHY、或指标不可信的线路不进候选；
    /// * 主备模式且策略为 follow 时只允许活动线路，
    ///   这样即使规则层写错也不会把游戏流量送到待命线路上。
    pub fn ranking(
        &self,
        cfg: &Config,
        slots: &BTreeMap<String, u8>,
        snap: &Snapshot,
        active: Option<&str>,
    ) -> Vec<Scored> {
        let mut out = Vec::new();
        for w in cfg
            .wans
            .iter()
            .filter(|w| w.enabled && w.role != WanRole::Monitor)
        {
            if w.maintenance {
                continue;
            }
            let Some(slot) = slots.get(&w.name).copied() else {
                continue;
            };
            let Some(h) = snap.get(&w.name) else { continue };
            if !h.usable_for_latency() {
                continue;
            }
            if cfg.global.mode == Mode::Failover
                && cfg.global.game_policy == GamePolicy::Follow
                && active.map(|a| a != w.name).unwrap_or(true)
            {
                continue;
            }
            let m = h.metrics.clone().unwrap_or_default();
            out.push(Scored::evaluate(
                &w.name, slot, h.state, &m, &cfg.score, 0.0,
            ));
        }
        out
    }

    /// 游戏规则择优：内部持有 [`latency::Picker`]，滞回与二次确认只此一份实现。
    pub fn pick_for_rule(
        &mut self,
        cfg: &Config,
        rule: &str,
        ranking: Vec<Scored>,
        now_ms: u64,
    ) -> latency::Pick {
        self.picker.pick(rule, ranking, &cfg.score, now_ms)
    }

    fn push_history(&mut self, at_ms: u64, text: &str) {
        self.history.push_back((at_ms, text.to_string()));
        while self.history.len() > HISTORY_MAX {
            self.history.pop_front();
        }
    }
}

/// 把 `system::assign_slots` 的结果规整成有序表（本层不依赖 hash 映射的遍历顺序）。
///
/// 槽位分配失败（启用线路超上限、段名重复）是配置错误，必须原样上抛：
/// 静默返回空表会让调度器以为「没有任何线路」，把配置问题伪装成运行问题。
pub fn slot_map(cfg: &Config) -> Result<BTreeMap<String, u8>> {
    Ok(crate::system::assign_slots(&cfg.wans)?
        .into_iter()
        .collect())
}

/// 组装主备判定所需的线路状态。
fn line_states(
    cfg: &Config,
    slots: &BTreeMap<String, u8>,
    snap: &Snapshot,
    now_ms: u64,
) -> Vec<LineState> {
    let mut out = Vec::with_capacity(cfg.wans.len());
    for w in &cfg.wans {
        let h = snap.get(&w.name);
        // 快照里没有该线路 = 守护进程还没为它建立追踪器（新增线路或刚重启）。
        // 此时不能默认「健康」，也不能留 blocked 为空让状态机去猜。
        let blocked = match (h, w.role) {
            (None, _) if w.enabled => Some(format!("尚无线路 {} 的健康数据", w.name)),
            (Some(h), _) => h.blocked_reason.clone(),
            (None, _) => None,
        };
        out.push(LineState {
            name: w.name.clone(),
            slot: slots.get(&w.name).copied().unwrap_or(0),
            enabled: w.enabled,
            maintenance: w.maintenance,
            state: h.map(|h| h.state).unwrap_or(State::Unknown),
            blocked,
            warmup_remaining_ms: h.map(|h| h.warmup_remaining_ms).unwrap_or(0),
            consec_ok: h.map(|h| h.consec_ok).unwrap_or(0),
            // 没有历史记录时把「进入当前状态的时间」记为现在：稳定计时从零开始。
            state_since_ms: h.map(|h| h.state_since_ms).unwrap_or(now_ms),
        });
    }
    out
}

/// 组装均衡分配所需的候选集。
fn candidates(
    cfg: &Config,
    slots: &BTreeMap<String, u8>,
    snap: &Snapshot,
    loads: &BTreeMap<String, Load>,
) -> Vec<balancing::Candidate> {
    let mut out = Vec::new();
    for w in cfg.wans.iter().filter(|w| w.role != WanRole::Monitor) {
        let Some(slot) = slots.get(&w.name).copied() else {
            continue;
        };
        let Some(h) = snap.get(&w.name) else { continue };
        let mut load = loads.get(&w.name).copied().unwrap_or_default();
        // 上限一律取配置值：采样层不该也没法决定「这条线路号称多少带宽」。
        load.down_kbps = w.down_kbps;
        load.up_kbps = w.up_kbps;
        load.conn_limit = cfg.global.max_connections_per_wan;
        out.push(balancing::Candidate {
            name: w.name.clone(),
            slot,
            weight: w.weight,
            priority: w.priority,
            usable: !w.maintenance && h.carries_normal_traffic(),
            degraded: h.state == State::Degraded,
            load,
        });
    }
    out.sort_by_key(|c| c.slot);
    out
}

/// 桶图 → 每条线路的桶数（按桶数降序、同数按名称，保证 UI 顺序稳定）。
fn share_of(buckets: &[u8], slots: &BTreeMap<String, u8>) -> Vec<(String, usize)> {
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for s in slots.values() {
        if let Some((name, _)) = slots.iter().find(|(_, v)| *v == s) {
            counts.entry(name).or_insert(0);
        }
    }
    for b in buckets {
        if *b == 0 {
            continue;
        }
        if let Some((name, _)) = slots.iter().find(|(_, v)| **v == *b) {
            *counts.entry(name).or_insert(0) += 1;
        }
    }
    let mut out: Vec<(String, usize)> = counts
        .into_iter()
        .map(|(n, c)| (n.to_string(), c))
        .filter(|(_, c)| *c > 0)
        .collect();
    out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    out
}

fn count_moves(previous: &[u8], now: &[u8]) -> usize {
    if previous.len() != now.len() {
        return now.iter().filter(|b| **b != 0).count();
    }
    previous
        .iter()
        .zip(now.iter())
        .filter(|(a, b)| a != b)
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::{Failback, GlobalConfig, HealthConfig, ScoreWeights, WanConfig};
    use crate::health::metrics::Metrics;
    use crate::health::WanHealth;

    fn metrics(rtt: u32) -> Metrics {
        Metrics {
            samples: 20,
            ok_samples: 20,
            rtt_ms: rtt,
            ..Default::default()
        }
    }

    fn scored(name: &str, slot: u8, rtt: u32) -> Scored {
        Scored::evaluate(
            name,
            slot,
            State::Healthy,
            &metrics(rtt),
            &ScoreWeights::default(),
            0.0,
        )
    }

    fn wan(name: &str, weight: u32, priority: u16) -> WanConfig {
        WanConfig {
            name: name.into(),
            enabled: true,
            weight,
            priority,
            ..Default::default()
        }
    }

    fn cfg(mode: Mode, algorithm: Algorithm, wans: Vec<WanConfig>) -> Config {
        Config {
            global: GlobalConfig {
                mode,
                algorithm,
                enabled: true,
                buckets: 64,
                rebalance_interval_ms: 2_000,
                smoothing_permille: 700,
                primary: "wan1".into(),
                backup_order: vec!["wan2".into(), "wan3".into()],
                failback: Failback::Auto,
                failback_delay_ms: 30_000,
                failback_success_threshold: 5,
                min_switch_interval_ms: 10_000,
                health: HealthConfig::default(),
                ..Default::default()
            },
            wans,
            games: Vec::new(),
            score: Default::default(),
        }
    }

    fn cfg_disabled(mode: Mode, algorithm: Algorithm, wans: Vec<WanConfig>) -> Config {
        let mut c = cfg(mode, algorithm, wans);
        c.global.enabled = false;
        c
    }

    fn health(name: &str, state: State, blocked: Option<String>) -> WanHealth {
        WanHealth {
            name: name.into(),
            state,
            metrics: None,
            last_outcome: None,
            last_transition: None,
            warmup_remaining_ms: 0,
            blocked_reason: blocked,
            state_since_ms: 0,
            consec_ok: if state == State::Healthy { 5 } else { 0 },
            consec_fail: 0,
            probes_total: 10,
            probes_ignored: 0,
        }
    }

    fn snap(wans: Vec<WanHealth>, measured: bool) -> Snapshot {
        Snapshot {
            wan: wans.into_iter().map(|w| (w.name.clone(), w)).collect(),
            at_ms: 1_000,
            measured,
        }
    }

    fn healthy_all() -> Snapshot {
        snap(
            vec![
                health("wan1", State::Healthy, None),
                health("wan2", State::Healthy, None),
                health("wan3", State::Healthy, None),
            ],
            true,
        )
    }

    #[test]
    fn failover_mode_points_every_bucket_at_the_active_line() {
        let c = cfg(
            Mode::Failover,
            Algorithm::SrcIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20), wan("wan3", 1, 30)],
        );
        let mut s = Scheduler::new();
        let o = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 1_000)
            .unwrap();
        assert_eq!(o.active.as_deref(), Some("wan1"));
        assert_eq!(o.buckets, vec![1u8; 64]);
        assert!(o.changed);
        assert_eq!(o.share, vec![("wan1".to_string(), 64)]);
        // 同一批数据再来一次：绝不能声称变更，否则数据面会被反复 replace。
        let o2 = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 2_000)
            .unwrap();
        assert!(!o2.changed, "{o2:?}");
        assert_eq!(o2.moved, 0);
    }

    #[test]
    fn failover_switches_and_explains_standby_and_game_policy() {
        let c = cfg(
            Mode::Failover,
            Algorithm::SrcIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20), wan("wan3", 1, 30)],
        );
        let mut s = Scheduler::new();
        s.decide(&c, &healthy_all(), &BTreeMap::new(), 1_000)
            .unwrap();
        let broken = snap(
            vec![
                health("wan1", State::Failed, None),
                health("wan2", State::Healthy, None),
                health("wan3", State::Healthy, None),
            ],
            true,
        );
        let o = s.decide(&c, &broken, &BTreeMap::new(), 5_000).unwrap();
        assert_eq!(o.active.as_deref(), Some("wan2"));
        assert!(o.changed);
        assert_eq!(o.buckets, vec![2u8; 64]);
        assert_eq!(o.standby, vec!["wan3".to_string()]);
        assert!(o.reason.contains("不可用"), "{}", o.reason);
        // 默认策略是 follow：必须明说待命线路不承载任何流量
        assert!(
            o.notes.iter().any(|n| n.contains("follow")),
            "{:?}",
            o.notes
        );

        let mut c2 = c.clone();
        c2.global.game_policy = GamePolicy::Exception;
        let o2 = s.decide(&c2, &broken, &BTreeMap::new(), 6_000).unwrap();
        assert!(
            o2.notes.iter().any(|n| n.contains("只可能被游戏")),
            "游戏例外必须写清待命线路只承载白名单流量: {:?}",
            o2.notes
        );
    }

    #[test]
    fn all_dead_stops_marking_instead_of_guessing() {
        let c = cfg(
            Mode::Failover,
            Algorithm::SrcIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        let dead = snap(
            vec![
                health("wan1", State::Failed, None),
                health("wan2", State::Failed, None),
            ],
            true,
        );
        let o = s.decide(&c, &dead, &BTreeMap::new(), 1_000).unwrap();
        assert!(o.all_dead);
        assert!(o.buckets.iter().all(|b| *b == 0), "全灭时不得留任何桶标记");
        assert!(!o.carries_traffic());
        assert!(o.share.is_empty());
    }

    #[test]
    fn unmeasured_snapshot_keeps_lines_unknown() {
        // 首轮探测完成前：所有线路 UNKNOWN，主备模式必须一条都不接流量。
        let c = cfg(Mode::Failover, Algorithm::SrcIp, vec![wan("wan1", 1, 10)]);
        let mut s = Scheduler::new();
        let empty = snap(vec![health("wan1", State::Unknown, None)], false);
        let o = s.decide(&c, &empty, &BTreeMap::new(), 1_000).unwrap();
        assert!(o.all_dead);
        assert!(
            o.notes.iter().any(|n| n.contains("首轮探测")),
            "必须明确告诉 UI「还没测过」: {:?}",
            o.notes
        );
        // 均衡模式同样不分流，且要给出可解释的原因而不是空白页。
        let c2 = cfg(Mode::Balance, Algorithm::SrcIp, vec![wan("wan1", 1, 10)]);
        let mut s2 = Scheduler::new();
        let o2 = s2.decide(&c2, &empty, &BTreeMap::new(), 1_000).unwrap();
        assert!(o2.buckets.iter().all(|b| *b == 0));
        assert!(o2.reason.contains("没有可用线路"), "{}", o2.reason);
    }

    #[test]
    fn balance_mode_splits_buckets_by_weight_and_stays_stable() {
        let c = cfg(
            Mode::Balance,
            Algorithm::WeightedHash,
            vec![wan("wan1", 3, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        let o = s
            .decide(&c, &healthy_all2(), &BTreeMap::new(), 1_000)
            .unwrap();
        assert_eq!(o.buckets.len(), 64);
        assert_eq!(o.active, None, "均衡模式没有活动线路概念");
        let total: usize = o.share.iter().map(|(_, n)| n).sum();
        assert_eq!(total, 64);
        // 3:1 权重 → 48:16，且必须先给桶多者（share 已降序）
        assert_eq!(o.share[0], ("wan1".to_string(), 48), "{:?}", o.share);
        assert_eq!(o.share[1], ("wan2".to_string(), 16), "{:?}", o.share);
        let o2 = s
            .decide(&c, &healthy_all2(), &BTreeMap::new(), 2_000)
            .unwrap();
        assert!(!o2.changed, "静态哈希在无健康变化时不得重排");
    }

    #[test]
    fn balance_mode_degrades_to_weights_when_load_samples_are_untrustworthy() {
        let c = cfg(
            Mode::Balance,
            Algorithm::LeastTraffic,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        // measured=false：动态算法不能假装知道谁更空
        let o = s
            .decide(&c, &healthy_all2(), &BTreeMap::new(), 1_000)
            .unwrap();
        assert!(
            o.notes.iter().any(|n| n.contains("采样不可信")),
            "必须说明本轮退回权重分配: {:?}",
            o.notes
        );
        assert_eq!(o.share.iter().map(|(_, n)| n).sum::<usize>(), 64);

        // 有可信采样且带宽上限不同：桶应偏向更空的线路
        let mut loads: BTreeMap<String, Load> = BTreeMap::new();
        loads.insert(
            "wan1".into(),
            Load {
                rx_kbps: 900_000,
                tx_kbps: 10_000,
                conns: 800,
                new_conns: 50,
                measured: true,
                ..Default::default()
            },
        );
        loads.insert(
            "wan2".into(),
            Load {
                rx_kbps: 10_000,
                tx_kbps: 5_000,
                conns: 20,
                new_conns: 1,
                measured: true,
                ..Default::default()
            },
        );
        let mut c2 = c.clone();
        c2.wans.iter_mut().for_each(|w| {
            w.down_kbps = 1_000_000;
            w.up_kbps = 100_000;
        });
        let mut s2 = Scheduler::new();
        let o2 = s2.decide(&c2, &healthy_all2(), &loads, 1_000).unwrap();
        assert_eq!(
            o2.share[0].0, "wan2",
            "更空的线路应拿到更多桶: {:?}",
            o2.share
        );
    }

    #[test]
    fn unsupported_algorithm_falls_back_without_breaking_the_loop() {
        let c = cfg(
            Mode::Balance,
            Algorithm::WeightedEcmp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        let o = s
            .decide(&c, &healthy_all2(), &BTreeMap::new(), 1_000)
            .unwrap();
        // 结果必须是可用算法，且降级过程被如实记录
        assert_eq!(o.algorithm, Algorithm::WeightedHash, "{o:?}");
        assert!(
            o.notes.iter().any(|n| n.contains("算法降级")),
            "{:?}",
            o.notes
        );
        assert_eq!(o.buckets.len(), 64);
    }

    #[test]
    fn monitor_and_maintenance_lines_are_excluded() {
        let mut m = wan("wan2", 1, 20);
        m.role = WanRole::Monitor;
        let mut keep = wan("wan3", 1, 30);
        keep.maintenance = true;
        let c = cfg(
            Mode::Balance,
            Algorithm::SrcIp,
            vec![wan("wan1", 1, 10), m, keep],
        );
        let mut s = Scheduler::new();
        let o = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 1_000)
            .unwrap();
        assert_eq!(
            o.share,
            vec![("wan1".to_string(), 64)],
            "仅探测与维护中的线路不能拿桶"
        );
        assert!(
            o.notes.iter().any(|n| n.contains("仅探测线路")),
            "{:?}",
            o.notes
        );
    }

    #[test]
    fn forced_switch_goes_through_the_scheduler() {
        let c = cfg(
            Mode::Failover,
            Algorithm::SrcIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20), wan("wan3", 1, 30)],
        );
        let mut s = Scheduler::new();
        s.decide(&c, &healthy_all(), &BTreeMap::new(), 1_000)
            .unwrap();
        s.force("wan3");
        let o = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 2_000)
            .unwrap();
        assert_eq!(o.active.as_deref(), Some("wan3"));
        assert!(o.reason.contains("强制"), "{}", o.reason);
        assert_eq!(s.forced(), Some("wan3"));
        s.release_forced();
        // 取消强制后不立刻回弹：靠回切条件决定，测试时间不足 → 保持
        let o2 = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 3_000)
            .unwrap();
        assert_eq!(o2.active.as_deref(), Some("wan3"));
        assert!(o2.waiting.is_some() || o2.reason.contains("保持"), "{o2:?}");
    }

    #[test]
    fn history_is_bounded_and_records_changes() {
        let c = cfg(
            Mode::Failover,
            Algorithm::SrcIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        let up = snap(
            vec![
                health("wan1", State::Healthy, None),
                health("wan2", State::Healthy, None),
            ],
            true,
        );
        let dead = snap(
            vec![
                health("wan1", State::Failed, None),
                health("wan2", State::Failed, None),
            ],
            true,
        );
        for i in 0..120u64 {
            // 交替「全灭 / 全好」制造每轮都变化的决策，用来验证历史上限
            let src = if i % 2 == 0 { &dead } else { &up };
            let o = s
                .decide(&c, src, &BTreeMap::new(), 1_000 + i * 60_000)
                .unwrap();
            assert!(o.changed, "第 {i} 轮本应发生变化: {o:?}");
        }
        let h = s.history();
        assert_eq!(h.len(), HISTORY_MAX, "历史必须有界，长跑进程不能无限增长");
        assert!(h.iter().all(|(t, _)| *t >= 1_000));
    }

    #[test]
    fn ranking_follows_health_and_game_policy() {
        let c = cfg(
            Mode::Failover,
            Algorithm::SrcIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let slots: BTreeMap<String, u8> = [("wan1", 1u8), ("wan2", 2)]
            .into_iter()
            .map(|(n, s)| (n.to_string(), s))
            .collect();
        let s = Scheduler::new();
        // follow：只有活动线路能进候选，待命线路绝不因为「分数更高」被偷偷用上
        let r = s.ranking(&c, &slots, &healthy_all2(), Some("wan1"));
        assert_eq!(r.len(), 1, "follow 策略下候选只能是活动线路: {r:?}");
        assert_eq!(r[0].name, "wan1");
        assert!(
            !r[0].confident,
            "缺指标时必须标记为不可信，让 Picker 拒绝改命"
        );
        assert!(
            s.ranking(&c, &slots, &healthy_all2(), None).is_empty(),
            "没有活动线路时 follow 不得给出候选"
        );

        let mut c2 = c.clone();
        c2.global.game_policy = GamePolicy::Exception;
        let r2 = s.ranking(&c2, &slots, &healthy_all2(), Some("wan1"));
        assert_eq!(r2.len(), 2, "开启游戏例外后待命线路进入候选");
        assert!(r2.iter().all(|x| !x.confident));

        // 状态非 HEALTHY 的线路永远不能承载游戏流量
        let bad = snap(
            vec![
                health("wan1", State::Degraded, None),
                health("wan2", State::Failed, None),
            ],
            true,
        );
        assert!(
            s.ranking(&c2, &slots, &bad, Some("wan1")).is_empty(),
            "降级/失败线路不得进低延迟候选"
        );
    }

    #[test]
    fn rule_picking_is_shared_and_forgettable() {
        let c = cfg(Mode::Failover, Algorithm::SrcIp, vec![wan("wan1", 1, 10)]);
        let mut s = Scheduler::new();
        let p = s.pick_for_rule(
            &c,
            "rule-a",
            vec![scored("wan1", 1, 120), scored("wan2", 2, 20)],
            1_000,
        );
        assert_eq!(p.chosen.as_deref(), Some("wan2"), "{p:?}");
        assert_eq!(s.picker().current("rule-a"), Some("wan2"));
        s.forget_rule("rule-a");
        assert_eq!(
            s.picker().current("rule-a"),
            None,
            "规则删除后不能留下幽灵选路状态"
        );
    }

    #[test]
    fn slot_overflow_is_reported_instead_of_hidden() {
        // 槽位分配失败是配置错误：必须上抛，不能退化成「看起来没有线路」
        let wans: Vec<WanConfig> = (0..=crate::marks::MAX_WANS)
            .map(|i| wan(&format!("w{i}"), 1, 100))
            .collect();
        let c = cfg(Mode::Balance, Algorithm::SrcIp, wans);
        let mut s = Scheduler::new();
        let e = s
            .decide(&c, &healthy_all2(), &BTreeMap::new(), 1_000)
            .unwrap_err();
        assert!(matches!(e, Error::Validate(_)), "{e}");
        assert!(e.to_string().contains("上限"), "{e}");
    }

    fn healthy_all2() -> Snapshot {
        snap(
            vec![
                health("wan1", State::Healthy, None),
                health("wan2", State::Healthy, None),
            ],
            true,
        )
    }

    #[test]
    fn config_change_resets_timers() {
        let c = cfg(
            Mode::Balance,
            Algorithm::LeastTraffic,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        s.decide(&c, &healthy_all2(), &BTreeMap::new(), 1_000)
            .unwrap();
        assert_ne!(s.last_rebalance_ms, 0);
        s.on_config_change();
        assert_eq!(
            s.last_rebalance_ms, 0,
            "配置变更后要允许立刻按新参数重排一次"
        );
    }

    // ==================== 真机实证回归 ====================

    #[test]
    fn disabled_config_yields_zero_buckets_and_no_traffic_claim() {
        // 真机实证：停用提交已清空内核对象后，调度层仍按健康状态给桶，
        // UI 显示「承载流量」而内核里没有任何本插件规则 —— 决策与数据面脱节。
        // 停用配置的决策必须是全零桶、carries_traffic=false。
        let c = cfg_disabled(
            Mode::Balance,
            Algorithm::SrcIpDstIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        let o = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 1_000)
            .unwrap();
        assert!(!o.carries_traffic(), "停用决策不得声称承载流量");
        assert!(o.buckets.iter().all(|b| *b == 0));
        assert!(o.reason.contains("停用"), "{:?}", o.reason);
    }

    #[test]
    fn disabled_decide_reports_changed_only_on_transition() {
        // 第一轮（此前有桶）changed=true 触发一次清场提交；内部状态同步归零后，
        // 后续轮必须 changed=false，否则守护进程每 tick 都会跑一次空事务。
        let c = cfg_disabled(
            Mode::Balance,
            Algorithm::SrcIpDstIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let mut s = Scheduler::new();
        // 先让机器处于「有桶」状态：启用决策一轮
        let on = cfg(
            Mode::Balance,
            Algorithm::SrcIpDstIp,
            vec![wan("wan1", 1, 10), wan("wan2", 1, 20)],
        );
        let o = s
            .decide(&on, &healthy_all(), &BTreeMap::new(), 1_000)
            .unwrap();
        assert!(o.carries_traffic());
        // 切停用：第一轮 changed=true（要清场）
        let o1 = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 2_000)
            .unwrap();
        assert!(o1.changed, "从有桶到全零必须触发一次停用提交");
        assert!(!o1.carries_traffic());
        // 第二轮起 changed=false（不得循环触发空事务）
        let o2 = s
            .decide(&c, &healthy_all(), &BTreeMap::new(), 3_000)
            .unwrap();
        assert!(!o2.changed, "停用后继续决策必须稳定为无变更");
        assert!(!o2.carries_traffic());
    }
}
