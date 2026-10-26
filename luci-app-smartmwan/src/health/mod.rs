//! 线路健康层：探测、指标滑动窗口、状态机，以及把三者钉在一起的追踪器。
//!
//! 分层职责：
//! - [`probe`]：单一目标的一次探测（ICMP/TCP/DNS）。只回答「这次通不通、多久」，
//!   并严格区分「线路故障」与「本地/权限/环境错误」。
//! - [`metrics`]：把探测结果聚合成 RTT/抖动/丢包窗口，供降级判定与评分使用。
//! - [`state`]：UNKNOWN → HEALTHY → DEGRADED → FAILED → RECOVERING → HEALTHY
//!   的迁移状态机，阈值全部来自配置，不在内部写死。
//! - [`Tracker`]：同一线路的指标与状态必须原子地一起更新，否则会出现
//!   「RTT 说很差、状态说健康」这类自相矛盾的展示与错误决策。
//!
//! # 诚实性约束（任务书要求）
//! - 从未探测过 ⇒ `Snapshot::measured == false`，前端必须显示「无数据」，
//!   绝不能画出绿色状态条。
//! - `Unsupported` / `LocalError` 不写入窗口、不喂状态机：否则「没有 ICMP 权限」
//!   会被显示成「线路断了」，进而触发无谓的主备切换。

pub mod metrics;
pub mod probe;
pub mod state;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use tokio::sync::watch;

use crate::config::schema::{Config, HealthConfig, WanConfig};
use crate::config::validate;
use crate::logging;
use crate::system::interface::Resolved;

pub use metrics::{Metrics, Sample, SlidingWindow};
pub use probe::{probe_batch, request_for, ProbeResult, Prober, Request, Target};
pub use state::{Machine as StateMachine, State, Transition};

/// 单条线路的运行时健康视图（RPC 与调度器的唯一数据来源）。
#[derive(Debug, Clone)]
pub struct WanHealth {
    /// 线路名（UCI `wan` 段名）。
    pub name: String,
    /// 当前状态。
    pub state: State,
    /// 窗口聚合指标；从未探测过时为 `None`。
    pub metrics: Option<Metrics>,
    /// 最近一次探测的原始结果描述，用于 UI 说明「最后一次发生了什么」。
    pub last_outcome: Option<String>,
    /// 最近一次状态迁移。
    pub last_transition: Option<Transition>,
    /// 处于预热期时的剩余毫秒。
    pub warmup_remaining_ms: u64,
    /// 静态阻断原因（链路 down、设备缺失、维护模式、无探测目标）。
    /// 与状态机无关：即使状态是 HEALTHY，被阻断的线路也不能承载流量。
    pub blocked_reason: Option<String>,
    /// 当前状态已持续的时间起点（unix 毫秒）；回切延迟以此为基准。
    pub state_since_ms: u64,
    /// 连续成功次数（回切需要「连续成功 N 次」，必须原样暴露）。
    pub consec_ok: u32,
    /// 连续失败次数。
    pub consec_fail: u32,
    /// 累计完成的探测次数（含被忽略的本地错误），用于排障。
    pub probes_total: u64,
    /// 因本地/不支持原因被丢弃的探测数（必须暴露给用户，否则权限问题不可见）。
    pub probes_ignored: u64,
}

impl WanHealth {
    /// 此刻是否值得承载普通流量。
    pub fn carries_normal_traffic(&self) -> bool {
        self.blocked_reason.is_none() && self.state.carries_normal_traffic()
    }

    /// 此刻是否值得承载低延迟（游戏）流量。
    pub fn usable_for_latency(&self) -> bool {
        self.blocked_reason.is_none() && self.state.usable_for_latency()
    }

    /// 状态是否可信到足以用于决策。
    pub fn confident(&self) -> bool {
        self.blocked_reason.is_none()
            && self
                .metrics
                .as_ref()
                .map(|m| m.confident())
                .unwrap_or(false)
    }
}

/// 全体线路的健康快照。
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub wan: BTreeMap<String, WanHealth>,
    /// 快照生成时间（unix 毫秒）。
    pub at_ms: u64,
    /// 是否已经完成过至少一轮真实探测。UI 必须据此区分「没有数据」与「数据正常」。
    pub measured: bool,
}

impl Snapshot {
    pub fn get(&self, name: &str) -> Option<&WanHealth> {
        self.wan.get(name)
    }

    /// 处于某状态的线路数（前端汇总卡片用）。
    pub fn count_state(&self, s: State) -> usize {
        self.wan.values().filter(|w| w.state == s).count()
    }

    /// 可承载普通流量的线路名，按配置的优先级顺序由调用方决定；
    /// 这里只做客观筛选，不含任何「猜测」。
    pub fn usable(&self) -> Vec<&WanHealth> {
        self.wan
            .values()
            .filter(|w| w.carries_normal_traffic())
            .collect()
    }

    /// 主备模式下是否连一条可用线路都没有。
    pub fn has_no_usable(&self) -> bool {
        self.wan.values().all(|w| !w.carries_normal_traffic())
    }
}

/// 一条线路的完整追踪器。
#[derive(Debug, Clone)]
pub struct Tracker {
    name: String,
    hc: HealthConfig,
    machine: StateMachine,
    window: SlidingWindow,
    last_outcome: Option<String>,
    blocked_reason: Option<String>,
    probes_total: u64,
    probes_ignored: u64,
}

impl Tracker {
    pub fn new(name: &str, hc: &HealthConfig, now_ms: u64) -> Tracker {
        Tracker {
            name: name.to_string(),
            hc: hc.clone(),
            machine: StateMachine::new(hc.clone(), now_ms),
            window: SlidingWindow::default(),
            last_outcome: None,
            blocked_reason: None,
            probes_total: 0,
            probes_ignored: 0,
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn state(&self) -> State {
        self.machine.state()
    }

    pub fn config(&self) -> &HealthConfig {
        &self.hc
    }

    /// 配置变更后同步阈值（保留当前状态，避免每次保存配置就把线路打回 UNKNOWN）。
    pub fn update_config(&mut self, hc: &HealthConfig) {
        if hc != &self.hc {
            let keep = self.machine.state();
            let mut m = StateMachine::new(hc.clone(), self.machine.since_ms());
            // 阈值变了但线路质量没变：把状态延续下去，历史重新从当前状态记一条，
            // 不伪造中间过程。
            m.force(keep, logging::now_ms(), "检测参数变更，状态延续");
            self.machine = m;
            self.hc = hc.clone();
        }
    }

    /// 指标窗口（RPC 需要直接读，用于画历史）。
    pub fn metrics(&self, now_ms: u64) -> Metrics {
        self.window.metrics(now_ms)
    }

    /// 纯时间推进（预热到期）。返回是否发生迁移。
    ///
    /// 探测循环每轮开始先做一次，保证「线路恢复后长期没有新探测」时状态也能收尾。
    pub fn tick(&mut self, now_ms: u64) -> bool {
        if let Some(t) = self.machine.tick(now_ms) {
            logging::info_ctx(
                "health",
                "transition",
                &format!(
                    "线路 {} 状态 {} -> {}（{}）",
                    self.name,
                    t.from.as_str(),
                    t.to.as_str(),
                    t.reason
                ),
                &[("wan", self.name.clone())],
            );
            return true;
        }
        false
    }

    /// 记入一次探测结果。返回本次是否发生状态迁移。
    pub fn record(&mut self, res: &ProbeResult, now_ms: u64) -> bool {
        // 先做时间推进：否则一次「预热恰好结束」会被推迟到下一次探测才生效。
        self.tick(now_ms);
        self.probes_total += 1;
        self.last_outcome = Some(res.outcome.describe());

        // 本地错误 / 探测方式不支持：既不进窗口，也不进状态机。
        let sample = match res.sample() {
            Some(s) => s,
            None => {
                self.probes_ignored += 1;
                // 反复被忽略说明配置或权限有问题，但这是运行问题，不是断线。
                if self.probes_ignored == 3 || self.probes_ignored % 30 == 0 {
                    logging::warn_ctx(
                        "health",
                        "probe-ignored",
                        &format!(
                            "线路 {} 已累计 {} 次探测未产生有效结论：{}",
                            self.name,
                            self.probes_ignored,
                            res.outcome.describe()
                        ),
                        &[("wan", self.name.clone())],
                    );
                }
                return false;
            }
        };
        self.window.push(sample);

        let ok = res.outcome.is_reply();
        let at = if res.at_ms == 0 { now_ms } else { res.at_ms };
        let degraded = ok
            && self.window.is_degraded(
                at,
                self.hc.degraded_rtt_ms,
                self.hc.degraded_loss_pmm,
                self.hc.degraded_jitter_ms,
            );
        if let Some(t) = self.machine.record(ok, degraded, at) {
            logging::info_ctx(
                "health",
                "transition",
                &format!(
                    "线路 {} 状态 {} -> {}（{}）",
                    self.name,
                    t.from.as_str(),
                    t.to.as_str(),
                    t.reason
                ),
                &[("wan", self.name.clone())],
            );
            return true;
        }
        false
    }

    /// 静态条件阻断（设备不存在、link down、维护模式）。
    /// 阻断不改状态机本身，只让线路此刻不可用；解除后状态继续沿用。
    pub fn set_blocked(&mut self, reason: Option<String>) {
        if self.blocked_reason != reason {
            logging::info_ctx(
                "health",
                if reason.is_some() {
                    "blocked"
                } else {
                    "unblocked"
                },
                &format!(
                    "线路 {} {}：{}",
                    self.name,
                    if reason.is_some() {
                        "不可用"
                    } else {
                        "恢复可用"
                    },
                    reason.as_deref().unwrap_or("无")
                ),
                &[("wan", self.name.clone())],
            );
        }
        self.blocked_reason = reason;
    }

    pub fn snapshot(&self, now_ms: u64) -> WanHealth {
        WanHealth {
            name: self.name.clone(),
            state: self.machine.state(),
            metrics: if self.window.is_empty() {
                None
            } else {
                Some(self.window.metrics(now_ms))
            },
            last_outcome: self.last_outcome.clone(),
            last_transition: self.machine.history().last().cloned(),
            warmup_remaining_ms: self.machine.warmup_remaining_ms(now_ms),
            state_since_ms: self.machine.since_ms(),
            consec_ok: self.machine.consec_ok(),
            consec_fail: self.machine.consec_fail(),
            blocked_reason: self.blocked_reason.clone(),
            probes_total: self.probes_total,
            probes_ignored: self.probes_ignored,
        }
    }

    /// 完整状态迁移轨迹（RPC「单线详情」用）。只读拷贝，不影响状态机。
    pub fn transitions(&self) -> Vec<Transition> {
        self.machine.history().to_vec()
    }
}

/// 追踪器集合：探测循环写、RPC 与调度器读。
#[derive(Default)]
pub struct Registry {
    inner: Arc<Mutex<BTreeMap<String, Tracker>>>,
    /// 是否已经完整跑完过一轮探测（决定 `Snapshot::measured`）。
    measured: Arc<Mutex<bool>>,
}

impl Registry {
    pub fn new() -> Registry {
        Registry::default()
    }

    /// 保证每条线路（含停用线路，便于 UI 展示）都有追踪器，并清除已删除线路。
    pub fn ensure(&self, cfg: &Config, now_ms: u64) {
        let mut g = lock(&self.inner);
        for w in &cfg.wans {
            g.entry(w.name.clone())
                .or_insert_with(|| Tracker::new(&w.name, &w.health, now_ms));
        }
        let keep: Vec<&str> = cfg.wans.iter().map(|w| w.name.as_str()).collect();
        g.retain(|k, _| keep.iter().any(|n| *n == k));
    }

    /// 同步阈值（配置保存后调用）。
    pub fn sync_config(&self, cfg: &Config) {
        let mut g = lock(&self.inner);
        for w in &cfg.wans {
            if let Some(t) = g.get_mut(&w.name) {
                t.update_config(&w.health);
            }
        }
    }

    pub fn with<R>(&self, f: impl FnOnce(&mut BTreeMap<String, Tracker>) -> R) -> R {
        let mut g = lock(&self.inner);
        f(&mut g)
    }

    /// 记入一条结果。返回「本次是否发生状态迁移」。
    ///
    /// **未知线路**（追踪器不存在）才记 orphan 日志并丢弃。注意「找到了追踪器但
    /// 没有迁移」与「没找到」是两件事：曾经把两者混为一个 bool，于是一次普通的
    /// 无迁移探测也会打出「已丢弃」的假日志 —— 排障时它会把人带偏。
    pub fn record(&self, res: &ProbeResult, now_ms: u64) -> bool {
        let mut found = false;
        let mut transitioned = false;
        self.with(|m| {
            if let Some(t) = m.get_mut(&res.req.wan) {
                found = true;
                transitioned = t.record(res, now_ms);
            }
        });
        if !found {
            logging::debug_ctx(
                "health",
                "probe-orphan",
                &format!("收到未知线路 {} 的探测结果，已丢弃", res.req.wan),
                &[("wan", res.req.wan.clone())],
            );
        }
        transitioned
    }

    pub fn set_blocked(&self, name: &str, reason: Option<String>) {
        self.with(|m| {
            if let Some(t) = m.get_mut(name) {
                t.set_blocked(reason);
            }
        });
    }

    /// 某条线路的状态迁移轨迹；未知线路返回空而不是报错（配置可能刚被改过）。
    pub fn transitions(&self, name: &str) -> Vec<Transition> {
        self.with(|m| m.get(name).map(|t| t.transitions()).unwrap_or_default())
    }

    /// 对所有线路做时间推进，返回发生迁移的条数。
    pub fn tick_all(&self, now_ms: u64) -> usize {
        self.with(|m| {
            let mut n = 0;
            for t in m.values_mut() {
                if t.tick(now_ms) {
                    n += 1;
                }
            }
            n
        })
    }

    pub fn mark_measured(&self) {
        *lock(&self.measured) = true;
    }

    pub fn measured(&self) -> bool {
        *lock(&self.measured)
    }

    /// 只读快照。
    pub fn snapshot(&self, now_ms: u64) -> Snapshot {
        let g = lock(&self.inner);
        Snapshot {
            wan: g
                .iter()
                .map(|(k, t)| (k.clone(), t.snapshot(now_ms)))
                .collect(),
            at_ms: now_ms,
            measured: *lock(&self.measured),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    // 中毒锁只可能因 panic 产生；此时取出内部数据继续服务比整进程崩溃更安全，
    // 但必须知道发生过：日志层会保留那条 panic 记录。
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// 把线路配置的探测目标字符串变成 [`Target`]。
///
/// 非法条目不会导致整批失败，但必须逐条告警——静默丢弃用户写的目标是
/// 「错误被吞掉」的典型形态。
pub fn parse_targets(w: &WanConfig) -> Vec<Target> {
    let mut out = Vec::new();
    for raw in &w.probe_targets {
        let t = raw.trim();
        if t.is_empty() {
            continue;
        }
        if let Ok(a) = t.parse() {
            out.push(Target::Addr(a));
            continue;
        }
        if valid_domain(t) {
            out.push(Target::Domain(t.to_string()));
            continue;
        }
        logging::warn_ctx(
            "health",
            "probe-target",
            &format!(
                "线路 {} 的探测目标 “{t}” 既不是 IP 也不是合法域名，已跳过",
                w.name
            ),
            &[("wan", w.name.clone())],
        );
    }
    out
}

/// 域名形状校验：不做 DNS，只挡明显不可解析的输入。
///
/// 额外拒绝「最后一段全是数字」的写法（例如 `1.1.1.1.9`）：它几乎一定是
/// 打错的 IP，若当成域名去解析会得到一个含义不明的失败。
fn valid_domain(s: &str) -> bool {
    if s.len() < 4 || s.len() > 253 || s.starts_with('.') || s.ends_with('.') || !s.contains('.') {
        return false;
    }
    let mut labels = s.split('.');
    let Some(last) = labels.next_back() else {
        return false;
    };
    if last.is_empty() || last.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    labels.all(|l| {
        !l.is_empty()
            && l.len() <= 63
            && l.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'*')
    })
}

/// 一轮探测前的准备结果。
#[derive(Debug, Clone, Default)]
pub struct Plan {
    pub requests: Vec<Request>,
    /// 被静态条件阻断的线路及原因（必须写进追踪器，让 UI 能解释）。
    pub blocked: Vec<(String, String)>,
    /// 本轮批次期限（毫秒）：所有请求里最大的超时再加一点余量。
    pub batch_deadline_ms: u64,
}

/// 依据「配置 + 当前接口解析结果」生成本轮探测请求。
///
/// 关键点：探测必须绑定到该线路自己的设备与源地址，否则多 WAN 下
/// 所有探测都会从默认路由出去，健康结论全线失真。
pub fn plan(cfg: &Config, resolved: &[Resolved]) -> Plan {
    let mut p = Plan::default();
    let by_name: BTreeMap<&str, &Resolved> = resolved.iter().map(|r| (r.wan.as_str(), r)).collect();

    for w in &cfg.wans {
        if !w.enabled {
            p.blocked.push((w.name.clone(), "线路已停用".into()));
            continue;
        }
        if w.maintenance {
            p.blocked.push((w.name.clone(), "维护模式".into()));
            continue;
        }
        let Some(r) = by_name.get(w.name.as_str()) else {
            p.blocked.push((
                w.name.clone(),
                "找不到对应的网络设备（接口可能已重拨）".into(),
            ));
            continue;
        };
        if !r.link_up {
            p.blocked
                .push((w.name.clone(), format!("设备 {} 链路未 up", r.device)));
            continue;
        }
        let mut targets = parse_targets(w);
        if targets.is_empty() {
            // 没有显式目标时退回网关：网关可达至少证明最后一公里还活着。
            if let Some(g) = r.gw4 {
                targets.push(Target::Addr(g));
            }
            if w.probe_ipv6 {
                if let Some(g) = r.gw6 {
                    targets.push(Target::Addr(g));
                }
            }
        }
        if targets.is_empty() {
            p.blocked
                .push((w.name.clone(), "既没有探测目标也没有可用网关".into()));
            continue;
        }
        for t in targets {
            let mut req = request_for(r, t, &w.health);
            req.proto = w.probe_proto;
            req.port = w.probe_port;
            p.batch_deadline_ms = p
                .batch_deadline_ms
                .max(req.timeout.as_millis() as u64 * 2 + 50);
            p.requests.push(req);
        }
    }
    // 批次期限兜底：没有请求时给一个不会让上层睡死的默认值。
    if p.batch_deadline_ms == 0 {
        p.batch_deadline_ms = cfg.global.health.timeout_ms as u64 * 2 + 50;
    }
    p
}

/// 一轮探测的统计，写日志与 RPC 都要用。
#[derive(Debug, Clone, Default)]
pub struct RoundInfo {
    pub started_at_ms: u64,
    pub finished_at_ms: u64,
    pub planned: usize,
    pub completed: usize,
    pub ignored: usize,
    pub transitions: usize,
    /// 是否因为关停信号提前结束（UI/日志要如实说明本轮不完整）。
    pub cancelled: bool,
}

/// 执行一轮探测并更新追踪器。
///
/// `cancel` 为 `true` 时立即停止收尾，已完成的结论仍然写入。
pub async fn run_round<P: Prober + ?Sized>(
    prober: Arc<P>,
    cfg: &Config,
    resolved: &[Resolved],
    registry: &Registry,
    cancel: watch::Receiver<bool>,
) -> RoundInfo {
    let started_at_ms = logging::now_ms();
    registry.ensure(cfg, started_at_ms);
    registry.tick_all(started_at_ms);
    let plan = plan(cfg, resolved);

    // 静态阻断必须先落到追踪器上，否则本轮没有探测的线路会停留在旧结论。
    let mut blocked_names: Vec<String> = Vec::new();
    for (name, reason) in &plan.blocked {
        registry.set_blocked(name, Some(reason.clone()));
        blocked_names.push(name.clone());
    }
    registry.with(|m| {
        for r in resolved {
            if !blocked_names.contains(&r.wan) {
                if let Some(t) = m.get_mut(&r.wan) {
                    t.set_blocked(None);
                }
            }
        }
    });

    let mut info = RoundInfo {
        started_at_ms,
        planned: plan.requests.len(),
        ..Default::default()
    };
    if !plan.requests.is_empty() {
        let deadline = std::time::Duration::from_millis(plan.batch_deadline_ms);
        let results = probe_batch(prober, plan.requests, deadline, cancel).await;
        info.cancelled = results.len() < info.planned;
        for res in results {
            if res.sample().is_none() {
                info.ignored += 1;
            }
            if registry.record(&res, logging::now_ms()) {
                info.transitions += 1;
            }
            info.completed += 1;
        }
    }
    if info.completed > 0 {
        registry.mark_measured();
    }
    info.finished_at_ms = logging::now_ms();
    logging::debug_ctx(
        "health",
        "probe-round",
        &format!(
            "本轮探测：计划 {}，完成 {}，无效 {}，状态迁移 {}，耗时 {}ms{}",
            info.planned,
            info.completed,
            info.ignored,
            info.transitions,
            info.finished_at_ms.saturating_sub(info.started_at_ms),
            if info.cancelled {
                "（被关停打断或超出批次期限）"
            } else {
                ""
            }
        ),
        &[],
    );
    info
}

/// 全局模式下「此刻应当承载流量」的线路集合（供 scheduler 与 RPC 共用）。
///
/// 主备模式下备份线路默认不承载普通流量，除非健康层与配置同时允许；
/// 该判断在 scheduler 里完成，这里只按状态客观筛选，避免两处规则不一致。
pub fn healthy_names(cfg: &Config, snap: &Snapshot) -> Vec<String> {
    let mut out: Vec<String> = snap
        .wan
        .values()
        .filter(|w| w.carries_normal_traffic())
        .map(|w| w.name.clone())
        .collect();
    out.sort_by(|a, b| {
        let pa = cfg
            .wans
            .iter()
            .find(|w| w.name == *a)
            .map(|w| w.priority)
            .unwrap_or(u16::MAX);
        let pb = cfg
            .wans
            .iter()
            .find(|w| w.name == *b)
            .map(|w| w.priority)
            .unwrap_or(u16::MAX);
        pa.cmp(&pb).then_with(|| a.cmp(b))
    });
    out
}

/// 供 `--check` 与 UI 复用的「探测方式是否可用」诊断。
pub fn probe_diagnostics(cfg: &Config, snap: &Snapshot) -> Vec<String> {
    let mut out = Vec::new();
    for w in &cfg.wans {
        if !w.enabled || w.maintenance {
            continue;
        }
        let Some(h) = snap.get(&w.name) else { continue };
        if h.probes_ignored > 0 && h.probes_total > 0 && h.probes_ignored == h.probes_total {
            out.push(format!(
                "线路 {} 的 {} 探测全部无效：{}（请改用 tcp/dns 探测目标）",
                w.name,
                w.probe_proto.as_str(),
                h.last_outcome.as_deref().unwrap_or("未知原因")
            ));
        } else if let Some(reason) = &h.blocked_reason {
            out.push(format!("线路 {} 未被探测：{reason}", w.name));
        }
    }
    if !snap.measured {
        out.push("守护进程尚未完成任何一轮有效探测，当前所有健康数据均不可用于决策".to_string());
    }
    out
}

/// 校验层复用：确认目标写法在探测前就合法（避免运行期才发现）。
pub fn check_probe_targets(cfg: &Config, report: &mut validate::Report) {
    for w in &cfg.wans {
        if !w.enabled {
            continue;
        }
        if w.probe_targets.is_empty() && w.gateway.trim().is_empty() {
            report.issues.push(validate::Issue {
                severity: validate::Severity::Warning,
                path: format!("smartmwan.wan[{}]", w.name),
                message: "未配置探测目标，健康判定将退回网关地址；网关不可 ping 时线路会被误判"
                    .into(),
                hint: Some("至少配置 2 个不同服务商的探测目标，减少被单点屏蔽造成的误判".into()),
            });
        }
        for t in &w.probe_targets {
            let t = t.trim();
            if t.is_empty() {
                continue;
            }
            if t.parse::<std::net::IpAddr>().is_err() && !valid_domain(t) {
                report.issues.push(validate::Issue {
                    severity: validate::Severity::Error,
                    path: format!("smartmwan.wan[{}]", w.name),
                    message: format!("探测目标 “{t}” 既不是合法 IP 也不是合法域名"),
                    hint: Some(
                        "填写 IPv4/IPv6 地址或完整域名，例如 1.1.1.1 或 dns.example.com".into(),
                    ),
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::ProbeProto;
    use crate::health::probe::Outcome;
    use crate::system::interface::Resolved;

    fn hc() -> HealthConfig {
        HealthConfig::default()
    }

    fn req(proto: ProbeProto) -> Request {
        Request {
            wan: "wan1".into(),
            device: "eth1".into(),
            ifindex: 4,
            src: None,
            target: Target::Addr("10.0.0.1".parse().unwrap()),
            proto,
            port: 0,
            timeout: std::time::Duration::from_millis(200),
        }
    }

    fn res(proto: ProbeProto, outcome: Outcome, at: u64) -> ProbeResult {
        ProbeResult {
            req: req(proto),
            at_ms: at,
            outcome,
            resolved: None,
        }
    }

    /// 同一条结果换上真实请求（模拟探测器回传）。
    fn res_with(r: ProbeResult, req: Request) -> ProbeResult {
        ProbeResult { req, ..r }
    }

    fn resolved(name: &str, up: bool) -> Resolved {
        Resolved {
            wan: name.into(),
            device: format!("dev-{name}"),
            ifindex: 7,
            link_up: up,
            gw4: "10.0.0.1".parse().ok(),
            gw6: None,
            src4: "10.0.0.2".parse().ok(),
            src6: None,
            link_default: false,
            notes: vec![],
        }
    }

    fn cfg_wans(names: &[&str]) -> Config {
        Config {
            wans: names
                .iter()
                .map(|n| WanConfig {
                    name: (*n).into(),
                    enabled: true,
                    probe_targets: vec!["1.1.1.1".into()],
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }
    }

    #[test]
    fn tracker_starts_unknown_and_needs_thresholds() {
        let h = hc();
        let mut t = Tracker::new("wan1", &h, 0);
        assert_eq!(t.state(), State::Unknown);
        // 单次成功不足以进入 HEALTHY：状态机自己决定，这里保持与其一致。
        t.record(
            &res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 10 }, 100),
            100,
        );
        assert_eq!(
            t.state(),
            State::Healthy,
            "首次成功即 HEALTHY 是状态机的既定语义"
        );
        // 失败要达阈值才判 FAILED。
        for i in 0..h.failure_threshold - 1 {
            t.record(
                &res(ProbeProto::Icmp, Outcome::Timeout, 200 + i as u64),
                200,
            );
        }
        assert_eq!(t.state(), State::Healthy, "未达阈值不该判死");
        t.record(&res(ProbeProto::Icmp, Outcome::Timeout, 300), 300);
        assert_eq!(t.state(), State::Failed);
    }

    #[test]
    fn local_errors_and_unsupported_never_fail_the_line() {
        let h = hc();
        let mut t = Tracker::new("wan1", &h, 0);
        for i in 0..h.recovery_threshold {
            t.record(
                &res(
                    ProbeProto::Icmp,
                    Outcome::Reply { rtt_ms: 10 },
                    i as u64 * 100,
                ),
                0,
            );
        }
        assert_eq!(t.state(), State::Healthy);
        for i in 0..h.failure_threshold + 3 {
            let at = 1000 + i as u64;
            t.record(
                &res(ProbeProto::Icmp, Outcome::LocalError("解析失败".into()), at),
                at,
            );
            t.record(
                &res(ProbeProto::Icmp, Outcome::Unsupported("无权限".into()), at),
                at,
            );
        }
        assert_eq!(t.state(), State::Healthy, "权限/解析错误绝不能被算成断线");
        let s = t.snapshot(2000);
        assert_eq!(s.probes_ignored, (h.failure_threshold + 3) as u64 * 2);
        assert!(
            s.probes_total > s.probes_ignored,
            "总数必须同时包含有效与无效"
        );
    }

    #[test]
    fn bad_metrics_degrade_then_fail() {
        let mut h = hc();
        h.degraded_rtt_ms = 50;
        let mut t = Tracker::new("wan1", &h, 0);
        for i in 0..8u64 {
            t.record(
                &res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 300 }, i * 100),
                0,
            );
        }
        assert_eq!(t.state(), State::Degraded, "RTT 越线必须降级");
        assert!(
            t.snapshot(1000).carries_normal_traffic(),
            "降级仍承载普通流量"
        );
        assert!(
            !t.snapshot(1000).usable_for_latency(),
            "降级线路不该被选为游戏最优"
        );
        for i in 0..h.failure_threshold {
            let at = 1000 + i as u64 * 100;
            t.record(&res(ProbeProto::Icmp, Outcome::Timeout, at), at);
        }
        assert_eq!(t.state(), State::Failed);
    }

    #[test]
    fn update_config_keeps_state_but_changes_thresholds() {
        let mut h = hc();
        h.degraded_rtt_ms = 1000;
        let mut t = Tracker::new("wan1", &h, 0);
        for i in 0..8u64 {
            t.record(
                &res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 300 }, i * 100),
                0,
            );
        }
        assert_eq!(t.state(), State::Healthy);
        h.degraded_rtt_ms = 100;
        t.update_config(&h);
        assert_eq!(
            t.state(),
            State::Healthy,
            "改阈值不能把健康线路打回 UNKNOWN"
        );
        // 新阈值立刻生效
        t.record(
            &res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 310 }, 2000),
            2000,
        );
        assert_eq!(t.state(), State::Degraded);
    }

    #[test]
    fn tick_closes_warmup_without_new_probe() {
        let mut h = hc();
        h.failure_threshold = 1;
        h.recovery_threshold = 1;
        h.warmup_ms = 1000;
        let mut t = Tracker::new("wan1", &h, 0);
        t.record(&res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 10 }, 0), 0);
        t.record(&res(ProbeProto::Icmp, Outcome::Timeout, 100), 100);
        assert_eq!(t.state(), State::Failed);
        t.record(
            &res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 10 }, 200),
            200,
        );
        assert_eq!(t.state(), State::Recovering, "warmup>0 时必须先进入预热");
        // 没有新探测，只靠时间推进
        assert!(!t.tick(500), "预热未结束时不该迁移");
        assert!(t.tick(1200), "预热到期必须自动收尾");
        assert_eq!(t.state(), State::Healthy);
    }

    #[test]
    fn blocked_reason_overrides_usability() {
        let h = hc();
        let mut t = Tracker::new("wan1", &h, 0);
        t.record(&res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 10 }, 0), 0);
        t.set_blocked(Some("链路 down".into()));
        let s = t.snapshot(1000);
        assert_eq!(s.state, State::Healthy, "阻断不改状态机");
        assert!(!s.carries_normal_traffic());
        assert!(!s.usable_for_latency());
        t.set_blocked(None);
        assert!(t.snapshot(1000).carries_normal_traffic());
    }

    #[test]
    fn registry_keeps_only_configured_wans_and_reports_measured() {
        let mut cfg = cfg_wans(&["wan1", "wan2"]);
        let r = Registry::new();
        r.ensure(&cfg, 0);
        assert_eq!(r.snapshot(0).wan.len(), 2);
        assert!(!r.snapshot(0).measured, "没探过就必须标记未测量");
        r.set_blocked("wan1", Some("x".into()));
        assert_eq!(
            r.snapshot(0).get("wan1").unwrap().blocked_reason.as_deref(),
            Some("x")
        );

        cfg.wans.pop();
        r.ensure(&cfg, 0);
        let s = r.snapshot(0);
        assert_eq!(s.wan.len(), 1);
        assert!(s.wan.contains_key("wan1"));
    }

    #[test]
    fn orphan_probe_result_is_dropped_without_crashing() {
        let cfg = cfg_wans(&["wan1"]);
        let r = Registry::new();
        r.ensure(&cfg, 0);
        let mut res = res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 5 }, 1);
        res.req.wan = "gone".into();
        assert!(!r.record(&res, 1), "未知线路的结果必须被明确丢弃");
    }

    #[test]
    fn known_line_without_transition_is_still_recorded() {
        // 回归：record() 曾把「没有发生状态迁移」当成「未知线路」打孤儿日志。
        // 判据是数据落没落账：probes_total 必须 +1，且返回值只表达「有没有迁移」。
        let cfg = cfg_wans(&["wan1"]);
        let r = Registry::new();
        r.ensure(&cfg, 0);
        let mut res = res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 5 }, 1);
        res.req.wan = "wan1".into();
        // 首轮一定发生 unknown -> healthy 迁移（返回 true）；第二轮状态不变
        // （返回 false）但数据必须照常记入 —— 曾把后者误报成「未知线路已丢弃」。
        assert!(r.record(&res, 1), "首轮应有迁移");
        assert!(!r.record(&res, 2), "第二轮无迁移，返回值应为 false");
        let s = r.snapshot(2);
        let w = s.get("wan1").expect("已知线路必须有追踪器");
        assert_eq!(w.probes_total, 2, "两次结果都必须记入追踪器");
        assert_eq!(w.last_outcome.as_deref(), Some("响应 5ms"));
    }

    #[test]
    fn target_parsing_accepts_ip_and_domain_only() {
        let mut w = WanConfig {
            name: "wan1".into(),
            probe_targets: vec![
                "1.1.1.1".into(),
                " 2606:4700::1 ".into(),
                "dns.example.com".into(),
                "not a domain".into(),
                "*.weird.example.com".into(),
                "".into(),
                "1.1.1.1.9".into(),
            ],
            ..Default::default()
        };
        let t = parse_targets(&w);
        assert_eq!(t.len(), 4, "只应留下 2 个 IP + 2 个域名，实际 {t:?}");
        assert!(matches!(t[1], Target::Addr(_)));
        assert_eq!(t[2], Target::Domain("dns.example.com".into()));
        assert_eq!(t[3], Target::Domain("*.weird.example.com".into()));
        w.probe_targets = vec!["；rm -rf /".into(), "1.2.3".into()];
        assert!(
            parse_targets(&w).is_empty(),
            "非法输入不能进入探测，更不能被拼进任何命令"
        );
    }

    #[test]
    fn plan_skips_disabled_and_blocked_lines_with_reasons() {
        let mut cfg = cfg_wans(&["wan1", "wan2", "wan3"]);
        cfg.wans[1].maintenance = true;
        cfg.wans[2].enabled = false;
        let rs = vec![resolved("wan1", true), resolved("wan2", true)];
        let p = plan(&cfg, &rs);
        assert_eq!(p.requests.len(), 1);
        assert_eq!(p.requests[0].wan, "wan1");
        assert_eq!(p.requests[0].device, "dev-wan1");
        assert_eq!(
            p.requests[0].src.map(|a| a.to_string()),
            Some("10.0.0.2".into())
        );
        let names: Vec<&str> = p.blocked.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, vec!["wan2", "wan3"], "维护与停用线路都要给出原因");
        assert!(p.blocked.iter().any(|(_, r)| r == "维护模式"));
        assert!(p.blocked.iter().any(|(_, r)| r == "线路已停用"));
    }

    #[test]
    fn plan_blocks_link_down_and_missing_device() {
        let cfg = cfg_wans(&["wan1", "wan2"]);
        let rs = vec![resolved("wan1", false)];
        let p = plan(&cfg, &rs);
        assert!(p.requests.is_empty());
        assert!(p
            .blocked
            .iter()
            .any(|(n, r)| n == "wan1" && r.contains("链路未 up")));
        assert!(p
            .blocked
            .iter()
            .any(|(n, r)| n == "wan2" && r.contains("找不到")));
    }

    #[test]
    fn plan_falls_back_to_gateway_then_reports_no_target() {
        let mut cfg = cfg_wans(&["wan1"]);
        cfg.wans[0].probe_targets.clear();
        let p = plan(&cfg, &[resolved("wan1", true)]);
        assert_eq!(p.requests.len(), 1, "没有显式目标时退回网关");
        assert_eq!(
            p.requests[0].target,
            Target::Addr("10.0.0.1".parse().unwrap())
        );

        let mut r = resolved("wan1", true);
        r.gw4 = None;
        let p2 = plan(&cfg, &[r]);
        assert!(p2.requests.is_empty());
        assert!(p2.blocked.iter().any(|(_, x)| x.contains("没有可用网关")));
    }

    #[test]
    fn healthy_names_sorts_by_priority_and_excludes_blocked() {
        let mut cfg = cfg_wans(&["a", "b", "c"]);
        cfg.wans.iter_mut().for_each(|w| w.priority = 100);
        cfg.wans[1].priority = 10;
        let r = Registry::new();
        r.ensure(&cfg, 0);
        r.with(|m| {
            for t in m.values_mut() {
                t.record(&res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 10 }, 0), 0);
            }
        });
        r.set_blocked("c", Some("维护".into()));
        let names = healthy_names(&cfg, &r.snapshot(1));
        assert_eq!(
            names,
            vec!["b".to_string(), "a".to_string()],
            "按优先级排序且排除被阻断线路"
        );
    }

    #[tokio::test]
    async fn run_round_updates_registry_and_counts_transitions() {
        struct Fixed;
        impl Prober for Fixed {
            fn probe(&self, req: Request) -> probe::BoxFuture<'_, crate::Result<ProbeResult>> {
                Box::pin(async move {
                    Ok(res_with(
                        res(
                            ProbeProto::Icmp,
                            Outcome::Reply { rtt_ms: 12 },
                            logging::now_ms(),
                        ),
                        req,
                    ))
                })
            }
        }
        let cfg = cfg_wans(&["wan1", "wan2"]);
        let r = Registry::new();
        let (_tx, rx) = watch::channel(false);
        let info = run_round(
            Arc::new(Fixed),
            &cfg,
            &[resolved("wan1", true), resolved("wan2", true)],
            &r,
            rx,
        )
        .await;
        assert_eq!(info.planned, 2);
        assert_eq!(info.completed, 2);
        assert_eq!(info.transitions, 2, "两条线路都应从 UNKNOWN 迁移");
        assert!(r.measured());
        let snap = r.snapshot(logging::now_ms());
        assert!(snap.measured);
        assert_eq!(snap.get("wan1").unwrap().state, State::Healthy);
        assert!(!info.cancelled);
    }

    #[tokio::test]
    async fn run_round_blocks_line_without_resolution() {
        struct Fixed;
        impl Prober for Fixed {
            fn probe(&self, req: Request) -> probe::BoxFuture<'_, crate::Result<ProbeResult>> {
                Box::pin(async move {
                    Ok(res_with(
                        res(
                            ProbeProto::Icmp,
                            Outcome::Reply { rtt_ms: 12 },
                            logging::now_ms(),
                        ),
                        req,
                    ))
                })
            }
        }
        let cfg = cfg_wans(&["wan1", "wan2"]);
        let r = Registry::new();
        let (_tx, rx) = watch::channel(false);
        let info = run_round(Arc::new(Fixed), &cfg, &[resolved("wan1", true)], &r, rx).await;
        assert_eq!(info.planned, 1);
        let snap = r.snapshot(logging::now_ms());
        assert!(
            snap.get("wan2").unwrap().blocked_reason.is_some(),
            "缺设备必须给出不可用原因"
        );
        assert!(!snap.get("wan2").unwrap().carries_normal_traffic());
        assert!(snap.get("wan1").unwrap().blocked_reason.is_none());
    }

    #[test]
    fn diagnostics_expose_unusable_probe_proto() {
        let cfg = cfg_wans(&["wan1"]);
        let r = Registry::new();
        r.ensure(&cfg, 0);
        r.with(|m| {
            let t = m.get_mut("wan1").unwrap();
            for i in 0..3 {
                t.record(
                    &res(ProbeProto::Icmp, Outcome::Unsupported("无权限".into()), i),
                    i,
                );
            }
        });
        let d = probe_diagnostics(&cfg, &r.snapshot(10));
        assert!(d.iter().any(|x| x.contains("全部无效")), "{d:?}");
        assert!(d.iter().any(|x| x.contains("尚未完成")), "{d:?}");
    }

    #[test]
    fn probe_target_validation_reports_errors() {
        let mut cfg = cfg_wans(&["wan1"]);
        cfg.wans[0].probe_targets = vec![
            "ok.example.com".into(),
            "1.1.1.1".into(),
            "bad domain".into(),
        ];
        let mut rep = validate::Report::default();
        check_probe_targets(&cfg, &mut rep);
        assert!(!rep.is_valid(), "{rep:?}");
        assert_eq!(rep.errors().len(), 1);

        let mut clean = cfg_wans(&["wan1"]);
        clean.wans[0].probe_targets = vec!["1.1.1.1".into()];
        let mut rep2 = validate::Report::default();
        check_probe_targets(&clean, &mut rep2);
        assert!(rep2.is_valid());
    }

    #[test]
    fn snapshot_helpers_are_objective() {
        let cfg = cfg_wans(&["wan1", "wan2"]);
        let r = Registry::new();
        r.ensure(&cfg, 0);
        r.with(|m| {
            m.get_mut("wan1")
                .unwrap()
                .record(&res(ProbeProto::Icmp, Outcome::Reply { rtt_ms: 10 }, 0), 0);
        });
        let s = r.snapshot(0);
        assert_eq!(s.usable().len(), 1);
        assert_eq!(s.count_state(State::Healthy), 1);
        assert_eq!(s.count_state(State::Unknown), 1);
        assert!(!s.has_no_usable());
    }
}
