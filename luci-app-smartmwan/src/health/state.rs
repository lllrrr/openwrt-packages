//! 线路健康状态机（纯逻辑，无 IO）。
//!
//! 状态迁移图（任务书要求可配置 + 可单测）：
//!
//! ```text
//!            首次探测成功                连续失败 >= failure_threshold
//!  UNKNOWN ───────────────► HEALTHY ◄───────────────────────┐
//!     │                       │  ▲                          │
//!     │  首次探测失败          │  │ rtt/丢包/抖动回到阈值内    │
//!     ▼                       ▼  │                          │
//!   UNKNOWN ──► DEGRADED ──► FAILED ──► RECOVERING ─────────┘
//!                 ▲  │          ▲            │
//!                 │  └──────────┘            │ 连续成功 >= recovery_threshold
//!                 └── 指标越过降级阈值         ▼ 且预热期结束 → HEALTHY
//! ```
//!
//! 三条硬约束：
//! 1. **UNKNOWN 不能当成 HEALTHY**。前端必须区分「没探过」与「健康」，
//!    否则刚重启的插件会显示一条漂亮的绿线，实际什么都没验证。
//! 2. **RECOVERING 期间不承载普通流量**（预热），避免线路刚回来就被推满，
//!    蜂窝链路上尤其重要（RRC 状态机、承载重建都需要时间）。
//! 3. **回切必须同时满足**：延迟（`failback_delay_ms`）+ 连续成功次数
//!    （`recovery_threshold`）+ 预热结束 + 最小切换间隔。缺任何一条都不切。

use std::fmt;

use crate::config::schema::HealthConfig;

/// 线路健康状态。字符串形式即 RPC/前端使用的稳定标识。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum State {
    /// 尚未得到任何探测结果（守护进程刚启动，或线路刚被启用）。
    Unknown,
    /// 指标在阈值内。
    Healthy,
    /// 连通但质量差（RTT/抖动/丢包越线）。
    Degraded,
    /// 判定不可用。
    Failed,
    /// 已恢复连通、正在预热，不承载普通流量。
    Recovering,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Unknown => "unknown",
            State::Healthy => "healthy",
            State::Degraded => "degraded",
            State::Failed => "failed",
            State::Recovering => "recovering",
        }
    }

    pub fn parse(s: &str) -> Option<State> {
        Some(match s.trim().to_ascii_lowercase().as_str() {
            "unknown" => State::Unknown,
            "healthy" => State::Healthy,
            "degraded" => State::Degraded,
            "failed" => State::Failed,
            "recovering" => State::Recovering,
            _ => return None,
        })
    }

    /// 是否可以承载普通（非游戏）流量。
    ///
    /// DEGRADED 仍算可用：质量差但不是断了，直接踢下线会造成比问题本身
    /// 更大的影响（所有连接重连）。是否降权由 scheduler 决定。
    pub fn carries_normal_traffic(self) -> bool {
        matches!(self, State::Healthy | State::Degraded)
    }

    /// 是否可用于游戏低延迟选路（RECOVERING/UNKNOWN 明确排除）。
    pub fn usable_for_latency(self) -> bool {
        matches!(self, State::Healthy)
    }

    /// 前端徽标语义：明确区分「未知」。
    pub fn is_unknown(self) -> bool {
        self == State::Unknown
    }
}

impl fmt::Display for State {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// 一次状态迁移的记录，进审计日志与前端时间线。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transition {
    pub at_ms: u64,
    pub from: State,
    pub to: State,
    /// 触发原因（人类可读，必须能解释「为什么切」）。
    pub reason: String,
}

/// 状态机实例。所有阈值来自 [`HealthConfig`]，不允许内部写死。
#[derive(Debug, Clone)]
pub struct Machine {
    state: State,
    cfg: HealthConfig,
    consec_ok: u32,
    consec_fail: u32,
    /// 进入当前状态的时间，用于最小切换间隔与预热判断。
    since_ms: u64,
    /// 上一次状态变化时间（含本次之前的那次）。
    last_change_ms: u64,
    /// 预热结束时间戳；`None` 表示无预热约束。
    warmup_until_ms: Option<u64>,
    history: Vec<Transition>,
}

/// 历史窗口上限：一条线路跑一年也不该吃掉内存。
const HISTORY_MAX: usize = 64;

impl Machine {
    pub fn new(cfg: HealthConfig, now_ms: u64) -> Machine {
        Machine {
            state: State::Unknown,
            cfg,
            consec_ok: 0,
            consec_fail: 0,
            since_ms: now_ms,
            last_change_ms: now_ms,
            warmup_until_ms: None,
            history: Vec::new(),
        }
    }

    pub fn state(&self) -> State {
        self.state
    }
    pub fn since_ms(&self) -> u64 {
        self.since_ms
    }
    pub fn consec_ok(&self) -> u32 {
        self.consec_ok
    }
    pub fn consec_fail(&self) -> u32 {
        self.consec_fail
    }
    pub fn warmup_remaining_ms(&self, now_ms: u64) -> u64 {
        self.warmup_until_ms
            .map(|t| t.saturating_sub(now_ms))
            .unwrap_or(0)
    }
    pub fn in_warmup(&self, now_ms: u64) -> bool {
        self.warmup_until_ms.map(|t| now_ms < t).unwrap_or(false)
    }
    pub fn history(&self) -> &[Transition] {
        &self.history
    }
    pub fn config(&self) -> &HealthConfig {
        &self.cfg
    }

    fn set(&mut self, to: State, now_ms: u64, reason: String) {
        if to == self.state {
            return;
        }
        self.history.push(Transition {
            at_ms: now_ms,
            from: self.state,
            to,
            reason,
        });
        if self.history.len() > HISTORY_MAX {
            let excess = self.history.len() - HISTORY_MAX;
            self.history.drain(0..excess);
        }
        self.state = to;
        self.last_change_ms = now_ms;
        self.since_ms = now_ms;
        match to {
            State::Recovering => {
                self.warmup_until_ms = Some(now_ms.saturating_add(self.cfg.warmup_ms));
            }
            State::Healthy | State::Degraded | State::Failed => {
                if !matches!(to, State::Recovering) {
                    self.warmup_until_ms = None;
                }
            }
            State::Unknown => self.warmup_until_ms = None,
        }
    }

    /// 记录一次探测结果并推进状态机。
    ///
    /// `ok`：探测是否得到响应；`degraded`：指标是否越过降级阈值（由 metrics 层判定）。
    /// 返回本次是否发生了状态变化，调用方据此写审计日志。
    pub fn record(&mut self, ok: bool, degraded: bool, now_ms: u64) -> Option<Transition> {
        if ok {
            self.consec_fail = 0;
            self.consec_ok = self.consec_ok.saturating_add(1);
        } else {
            self.consec_ok = 0;
            self.consec_fail = self.consec_fail.saturating_add(1);
        }
        let before = self.state;

        match self.state {
            State::Unknown => {
                if ok {
                    self.set(State::Healthy, now_ms, "首次探测成功".into());
                } else if self.consec_fail >= self.cfg.failure_threshold.max(1) {
                    self.set(
                        State::Failed,
                        now_ms,
                        format!("启动即连续失败 {} 次", self.consec_fail),
                    );
                }
            }
            State::Healthy => {
                if !ok && self.consec_fail >= self.cfg.failure_threshold.max(1) {
                    self.set(
                        State::Failed,
                        now_ms,
                        format!(
                            "连续失败 {} 次（阈值 {}）",
                            self.consec_fail, self.cfg.failure_threshold
                        ),
                    );
                } else if degraded && ok {
                    self.set(State::Degraded, now_ms, "连通但指标越过降级阈值".into());
                }
            }
            State::Degraded => {
                if !ok && self.consec_fail >= self.cfg.failure_threshold.max(1) {
                    self.set(
                        State::Failed,
                        now_ms,
                        format!("降级中连续失败 {} 次", self.consec_fail),
                    );
                } else if ok && !degraded {
                    self.set(State::Healthy, now_ms, "指标回到阈值内".into());
                }
            }
            State::Failed => {
                if ok && self.consec_ok >= self.cfg.recovery_threshold.max(1) {
                    self.set(
                        State::Recovering,
                        now_ms,
                        format!("连续成功 {} 次，进入预热", self.consec_ok),
                    );
                    // warmup=0 时 RECOVERING 只是瞬时状态：必须在同一次探测里完成
                    // 收尾，否则「阈值 1 + 预热 0」这种最简配置会永远卡在 RECOVERING，
                    // 线路明明通了却不承载流量。
                    if self.cfg.warmup_ms == 0 {
                        if degraded {
                            self.set(State::Degraded, now_ms, "预热期为 0，立即判定为降级".into());
                        } else {
                            self.set(State::Healthy, now_ms, "预热期为 0，立即判定恢复".into());
                        }
                    }
                }
            }
            State::Recovering => {
                if !ok {
                    // 预热期再次失败：直接打回 FAILED 并重置计数，
                    // 不给「时好时坏」的线路反复上线的机会。
                    self.consec_ok = 0;
                    self.set(State::Failed, now_ms, "预热期再次失败".into());
                } else if !self.in_warmup(now_ms) {
                    if degraded {
                        self.set(State::Degraded, now_ms, "预热结束但指标仍偏差".into());
                    } else {
                        self.set(State::Healthy, now_ms, "预热结束，判定恢复".into());
                    }
                }
            }
        }
        if before != self.state {
            self.history.last().cloned()
        } else {
            None
        }
    }

    /// 时间驱动的迁移：即使这一轮没有新探测结果（例如探测目标全部非法），
    /// 预热到期的 RECOVERING 也必须能自己走到 HEALTHY，否则会永久卡在不可用。
    ///
    /// 只处理 RECOVERING，其余状态一律由探测结果驱动。
    pub fn tick(&mut self, now_ms: u64) -> Option<Transition> {
        if !matches!(self.state, State::Recovering) || self.in_warmup(now_ms) {
            return None;
        }
        if self.consec_ok == 0 {
            // 没有成功记录作为依据，不凭空判定恢复。
            return None;
        }
        self.set(State::Healthy, now_ms, "预热时间结束".into());
        if self.state == State::Healthy {
            self.history.last().cloned()
        } else {
            None
        }
    }

    /// 预热结束时间是否已到 + 是否满足最小切换间隔。由 scheduler 在切换前调用。
    ///
    /// 这里是「回切条件」的唯一实现处，避免主备逻辑与状态机各说各话。
    pub fn ready_for_promotion(
        &self,
        now_ms: u64,
        min_switch_interval_ms: u64,
    ) -> Result<(), String> {
        // 预热检查必须排在状态检查之前：RECOVERING 本身就在预热中，
        // 若先报「状态不符」就看不出到底是「还在预热」还是「根本没恢复」。
        if self.in_warmup(now_ms) {
            return Err(format!(
                "预热未结束，剩余 {}ms",
                self.warmup_remaining_ms(now_ms)
            ));
        }
        if !matches!(self.state, State::Healthy) {
            return Err(format!("当前状态 {}，不满足升级条件", self.state));
        }
        if now_ms.saturating_sub(self.last_change_ms) < min_switch_interval_ms {
            return Err(format!(
                "距上次状态变化 {}ms，小于最小切换间隔 {}ms",
                now_ms.saturating_sub(self.last_change_ms),
                min_switch_interval_ms
            ));
        }
        Ok(())
    }

    /// 外部强制置为 FAILED（维护模式、手动切换）。计数复位，避免残留影响判定。
    pub fn force(&mut self, to: State, now_ms: u64, reason: &str) {
        self.consec_ok = 0;
        self.consec_fail = 0;
        self.set(to, now_ms, format!("强制置为 {to}：{reason}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> HealthConfig {
        HealthConfig {
            interval_ms: 1000,
            timeout_ms: 800,
            failure_threshold: 3,
            recovery_threshold: 5,
            warmup_ms: 5000,
            degraded_rtt_ms: 150,
            degraded_loss_pmm: 50,
            degraded_jitter_ms: 40,
            max_concurrent_probes: 8,
        }
    }

    #[test]
    fn unknown_is_not_healthy_and_needs_threshold_before_failing() {
        let mut m = Machine::new(cfg(), 0);
        assert_eq!(m.state(), State::Unknown);
        assert!(
            !m.state().carries_normal_traffic(),
            "未验证的线路不能承载流量"
        );
        // 单次失败不应直接判定 FAILED（阈值 3）
        m.record(false, false, 1);
        assert_eq!(m.state(), State::Unknown);
        m.record(false, false, 2);
        m.record(false, false, 3);
        assert_eq!(m.state(), State::Failed);
        assert!(m
            .history()
            .iter()
            .any(|t| t.reason.contains("启动即连续失败")));
    }

    #[test]
    fn first_success_healthy_then_fail_after_threshold() {
        let mut m = Machine::new(cfg(), 0);
        assert_eq!(
            m.record(true, false, 10),
            Some(Transition {
                at_ms: 10,
                from: State::Unknown,
                to: State::Healthy,
                reason: "首次探测成功".into(),
            })
        );
        for i in 1..=2 {
            assert!(m.record(false, false, 20 + i).is_none(), "未达阈值不应迁移");
        }
        assert_eq!(m.state(), State::Healthy);
        assert!(m.record(false, false, 25).is_some());
        assert_eq!(m.state(), State::Failed);
    }

    #[test]
    fn any_success_resets_failure_counter() {
        let mut m = Machine::new(cfg(), 0);
        m.record(true, false, 1);
        m.record(false, false, 2);
        m.record(false, false, 3);
        m.record(true, false, 4); // 计数复位
        m.record(false, false, 5);
        m.record(false, false, 6);
        assert_eq!(m.state(), State::Healthy, "断续失败不能被累加成断线");
        assert_eq!(m.consec_fail(), 2);
    }

    #[test]
    fn degraded_is_reachable_and_recoverable() {
        let mut m = Machine::new(cfg(), 0);
        m.record(true, false, 1);
        assert_eq!(m.state(), State::Healthy);
        m.record(true, true, 2);
        assert_eq!(m.state(), State::Degraded);
        assert!(m.state().carries_normal_traffic(), "降级仍可用，只是质量差");
        assert!(
            !m.state().usable_for_latency(),
            "降级线路不该被选为游戏最优"
        );
        m.record(true, false, 3);
        assert_eq!(m.state(), State::Healthy);
        // 降级期间真的断了：仍然按阈值判 FAILED
        m.record(true, true, 4);
        for i in 5..8 {
            m.record(false, true, i);
        }
        assert_eq!(m.state(), State::Failed);
    }

    #[test]
    fn recovery_requires_threshold_then_warmup_then_healthy() {
        let mut m = Machine::new(cfg(), 0);
        m.record(true, false, 1);
        for i in 2..5 {
            m.record(false, false, i);
        }
        assert_eq!(m.state(), State::Failed);
        // 4 次成功还不够（阈值 5）
        for i in 5..9 {
            m.record(true, false, i);
        }
        assert_eq!(m.state(), State::Failed);
        let t = m.record(true, false, 9).expect("第 5 次成功应触发");
        assert_eq!((t.from, t.to), (State::Failed, State::Recovering));
        assert!(m.in_warmup(10), "刚进入 RECOVERING 必须在预热中");
        assert!(!m.state().carries_normal_traffic(), "预热期不承载普通流量");
        // 预热未结束时不升级到 HEALTHY
        m.record(true, false, 1000);
        assert_eq!(m.state(), State::Recovering);
        // 5000ms 预热结束后
        m.record(true, false, 6000);
        assert_eq!(m.state(), State::Healthy);
        assert!(!m.in_warmup(6000));
        assert_eq!(m.warmup_remaining_ms(6000), 0);
    }

    #[test]
    fn failure_during_warmup_goes_straight_back_to_failed() {
        let mut m = Machine::new(cfg(), 0);
        m.record(true, false, 1);
        for i in 2..6 {
            m.record(false, false, i);
        }
        for i in 6..11 {
            m.record(true, false, i);
        }
        assert_eq!(m.state(), State::Recovering);
        m.record(false, false, 12);
        assert_eq!(m.state(), State::Failed);
        assert_eq!(m.consec_ok(), 0, "预热期失败必须清空成功计数");
        assert!(m
            .history()
            .iter()
            .any(|t| t.reason.contains("预热期再次失败")));
    }

    #[test]
    fn warmup_end_with_bad_metrics_lands_on_degraded() {
        let mut m = Machine::new(cfg(), 0);
        m.record(true, false, 1);
        for i in 2..6 {
            m.record(false, false, i);
        }
        for i in 6..11 {
            m.record(true, false, i);
        }
        assert_eq!(m.state(), State::Recovering);
        m.record(true, true, 7000);
        assert_eq!(
            m.state(),
            State::Degraded,
            "预热结束但指标仍差 → 降级，不给健康"
        );
    }

    #[test]
    fn promotion_gate_checks_state_warmup_and_min_interval() {
        let mut m = Machine::new(cfg(), 0);
        assert!(m.ready_for_promotion(0, 0).is_err(), "UNKNOWN 不能被提升");
        m.record(true, false, 1);
        assert!(m.ready_for_promotion(1, 0).is_ok());
        // 失败后恢复：预热期 + 最小间隔双重约束
        for i in 2..6 {
            m.record(false, false, i);
        }
        for i in 6..11 {
            m.record(true, false, i);
        }
        assert_eq!(m.state(), State::Recovering);
        let err = m.ready_for_promotion(11, 0).unwrap_err();
        assert!(err.contains("预热"), "{err}");
        // 纯时间推进：预热到期后 RECOVERING 自动收尾为 HEALTHY
        assert_eq!(
            m.tick(5010).map(|t| (t.from, t.to)),
            Some((State::Recovering, State::Healthy))
        );
        // 收尾的那一刻也算「状态变化」：紧接着就要切换出口仍被最小间隔挡住，
        // 这正是防抖的目的（线路刚活就推满流量会引发二次抖动）。
        let err = m.ready_for_promotion(5010, 120_000).unwrap_err();
        assert!(err.contains("最小切换间隔"), "{err}");
        assert!(m.ready_for_promotion(6010, 1000).is_ok());
    }

    #[test]
    fn force_resets_counters_and_keeps_history_bounded() {
        let mut m = Machine::new(cfg(), 0);
        for i in 0..200 {
            m.record(i % 3 == 0, false, i);
            if m.state() == State::Failed {
                m.force(State::Recovering, i, "测试");
            }
        }
        assert!(m.history().len() <= 64, "历史必须封顶，长跑不能吃内存");
        m.force(State::Failed, 999, "维护模式");
        assert_eq!(m.state(), State::Failed);
        assert_eq!(m.consec_ok(), 0);
        assert!(!m.in_warmup(1000));
    }

    #[test]
    fn thresholds_of_one_are_honoured() {
        // 用户把阈值改成 1：一次失败就应判定，不能有「最小 3 次」这种隐藏下限。
        let mut c = cfg();
        c.failure_threshold = 1;
        c.recovery_threshold = 1;
        c.warmup_ms = 0;
        let mut m = Machine::new(c, 0);
        m.record(true, false, 1);
        m.record(false, false, 2);
        assert_eq!(m.state(), State::Failed);
        m.record(true, false, 3);
        assert_eq!(m.state(), State::Healthy, "warmup=0 时恢复立即完成");
    }

    #[test]
    fn state_strings_are_stable_for_rpc() {
        for s in [
            State::Unknown,
            State::Healthy,
            State::Degraded,
            State::Failed,
            State::Recovering,
        ] {
            assert_eq!(State::parse(s.as_str()), Some(s), "字符串必须可往返");
        }
        assert_eq!(State::parse("ok"), None, "未知字符串不能被猜成某个状态");
        assert_eq!(State::Failed.to_string(), "failed");
    }
}
