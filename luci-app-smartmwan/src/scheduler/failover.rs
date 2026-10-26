//! 主备（故障切换）模式：同一时刻只有一条线路承载普通流量，其余待命。
//!
//! # 语义（与 UI 文案一一对应）
//!
//! * **顺序**：`global.primary` 优先，其次按 `global.backup_order` 列出的顺序，
//!   最后把其余线路按槽位（槽位由 `system::assign_slots` 依 role/priority/name
//!   分配）补齐。顺序完全确定，不随运行时健康抖动而改变 —— 否则「主线路」这个
//!   概念就没有意义了。
//! * **切换**：当前活动线路不可用（FAILED / UNKNOWN / 维护 / 静态阻断 / 已从配置
//!   消失）即切到顺序里下一条可用的线路。
//! * **回切**：仅当 `failback=auto` 且更高优先线路同时满足
//!   ①状态 HEALTHY 且预热已结束、②当前状态已持续 ≥ `failback_delay_ms`、
//!   ③连续成功次数 ≥ `failback_success_threshold`、④距上次切换 ≥ `min_switch_interval_ms`
//!   —— 四条全部满足，再经二次确认后回切。缺任何一条都不切，并把「还差什么」交出去。
//! * **手动回切**：`failback=manual` 时永不自动回切，只能由 RPC 强制切换。
//! * **全部不可用**：`active = None`，桶图全 0（不标记），流量退回系统默认路由。
//!   UI 必须显示「无可用线路」，而不是假装还在正常工作。
//!
//! 待命的备份线路**不承载普通流量**；游戏流量是否允许例外由 `global.game_policy`
//! 决定，具体判定在 `rules`/`latency` 层，本模块只负责普通流量的活动线路。

use std::collections::BTreeMap;

use crate::config::schema::{Failback, GlobalConfig};
use crate::health::state::State;

use super::hysteresis::{interval_elapsed, Debounce};

/// 一条线路在主备决策时刻的状态。
#[derive(Debug, Clone)]
pub struct LineState {
    pub name: String,
    pub slot: u8,
    pub enabled: bool,
    pub maintenance: bool,
    pub state: State,
    /// 健康层的静态阻断原因（设备缺失 / 链路 down / 无探测目标）。
    pub blocked: Option<String>,
    pub warmup_remaining_ms: u64,
    pub consec_ok: u32,
    /// 进入当前状态的时间（回切延迟以此为基准）。
    pub state_since_ms: u64,
}

impl LineState {
    /// 能否作为「活动线路」承载普通流量。
    ///
    /// UNKNOWN 明确排除：没验证过的线路不能接流量。
    pub fn usable_as_active(&self) -> bool {
        self.enabled
            && !self.maintenance
            && self.blocked.is_none()
            && self.state.carries_normal_traffic()
    }

    /// 能否作为「回切目标」（比活动条件更严格）。
    pub fn eligible_for_failback(&self) -> bool {
        self.usable_as_active() && self.state == State::Healthy && self.warmup_remaining_ms == 0
    }

    /// 不可用的具体原因（`None` 表示可用）。UI 与审计日志都靠它解释切换。
    pub fn unusable_reason(&self) -> Option<String> {
        if !self.enabled {
            return Some("线路已停用".into());
        }
        if self.maintenance {
            return Some("维护模式".into());
        }
        if let Some(b) = &self.blocked {
            return Some(b.clone());
        }
        match self.state {
            State::Unknown => Some("尚未完成健康验证".into()),
            State::Failed => Some("健康检测判定不可用".into()),
            State::Recovering => Some(format!("预热中（剩余 {}ms）", self.warmup_remaining_ms)),
            _ => None,
        }
    }
}

/// 一次主备决策的输出。
#[derive(Debug, Clone, PartialEq)]
pub struct Decision {
    /// 此刻应承载普通流量的线路；`None` = 不分流。
    pub active: Option<String>,
    /// 本轮活动线路是否发生变化（决定数据面要不要 replace 规则）。
    pub changed: bool,
    /// 决策依据，可直接显示给用户。
    pub reason: String,
    /// 正在等待回切的线路与还差的条件。
    pub waiting: Option<(String, String)>,
    /// 一条可用线路都没有。
    pub all_dead: bool,
    /// 主备顺序（UI 展示「主 / 备1 / 备2 …」）。
    pub order: Vec<String>,
}

impl Decision {
    /// 活动线路的槽位；`None` → 0，表示不写标记。
    pub fn active_slot(&self, slots: &BTreeMap<String, u8>) -> u8 {
        self.active
            .as_ref()
            .and_then(|n| slots.get(n).copied())
            .unwrap_or(0)
    }

    /// 主备模式桶图：所有桶指向同一槽位。
    pub fn bucket_map(&self, slots: &BTreeMap<String, u8>, buckets: usize) -> Vec<u8> {
        vec![self.active_slot(slots); buckets]
    }

    /// 待命线路（顺序里排在活动线路之后且本身可用的）。
    pub fn standby(&self, lines: &[LineState]) -> Vec<String> {
        let cur = match &self.active {
            Some(c) => c.clone(),
            None => return Vec::new(),
        };
        self.order
            .iter()
            .skip_while(|n| **n != cur)
            .skip(1)
            .filter(|n| {
                lines
                    .iter()
                    .find(|l| l.name == **n)
                    .map(|l| l.usable_as_active())
                    .unwrap_or(false)
            })
            .cloned()
            .collect()
    }
}

/// 有状态的主备机：记住当前活动线路、上次切换时间与回切去抖进度。
#[derive(Default)]
pub struct Machine {
    active: Option<String>,
    last_switch_ms: u64,
    /// 回切去抖：(目标线路, 去抖器)。
    failback: Option<(String, Debounce)>,
    /// RPC 强制目标（可用期间生效）。
    forced: Option<String>,
}

impl Machine {
    pub fn new() -> Machine {
        Machine::default()
    }

    pub fn active(&self) -> Option<&str> {
        self.active.as_deref()
    }

    pub fn last_switch_ms(&self) -> u64 {
        self.last_switch_ms
    }

    pub fn forced(&self) -> Option<&str> {
        self.forced.as_deref()
    }

    /// RPC：强制切换（用户明确意志，绕过回切条件）。
    ///
    /// 目标当前不可用时**不清除** forced，等它可用后立刻生效 —— 用户点「强制切到
    /// wan3」而 wan3 正断着时，静默丢弃指令比等待更糟。
    pub fn force(&mut self, target: &str) {
        self.forced = Some(target.to_string());
        self.failback = None;
    }

    /// RPC：取消强制，回到自动顺序逻辑（不会立即改回自动选路结果）。
    pub fn release_forced(&mut self) {
        self.forced = None;
        self.failback = None;
    }

    /// 配置变更后复位去抖计时，避免带着旧配置的计数做新决策。
    pub fn reset_debounce(&mut self) {
        self.failback = None;
    }

    /// 依据配置与线路状态决定此刻的活动线路。
    pub fn decide(&mut self, cfg: &GlobalConfig, lines: &[LineState], now_ms: u64) -> Decision {
        let order = order(cfg, lines);
        let by_name: BTreeMap<&str, &LineState> =
            lines.iter().map(|l| (l.name.as_str(), l)).collect();
        let usable: Vec<&str> = order
            .iter()
            .filter(|n| {
                by_name
                    .get(n.as_str())
                    .map(|l| l.usable_as_active())
                    .unwrap_or(false)
            })
            .map(|n| n.as_str())
            .collect();

        // 1) 强制目标优先（可用即生效）。
        if let Some(f) = self.forced.clone() {
            if by_name
                .get(f.as_str())
                .map(|l| l.usable_as_active())
                .unwrap_or(false)
            {
                return self.commit(
                    Some(f.clone()),
                    &order,
                    now_ms,
                    format!("强制切换到 {f}"),
                    None,
                    false,
                );
            }
        }

        // 2) 全部不可用：明确停止分流。
        if usable.is_empty() {
            self.failback = None;
            let reasons: Vec<String> = order
                .iter()
                .filter_map(|n| by_name.get(n.as_str()))
                .filter_map(|l| l.unusable_reason().map(|r| format!("{}：{r}", l.name)))
                .collect();
            let why = if reasons.is_empty() {
                "没有配置任何线路".to_string()
            } else {
                format!("所有线路均不可用（{}）", reasons.join("；"))
            };
            return self.commit(None, &order, now_ms, why, None, true);
        }

        let next_best = usable[0];
        let current_usable = self
            .active
            .as_ref()
            .map(|a| {
                by_name
                    .get(a.as_str())
                    .map(|l| l.usable_as_active())
                    .unwrap_or(false)
            })
            .unwrap_or(false);

        // 3) 活动线路仍然可用 —— 判断是否回切。
        if current_usable {
            let cur = self.active.clone().unwrap_or_default();
            let cur_idx = order.iter().position(|n| *n == cur).unwrap_or(usize::MAX);
            let best_idx = order
                .iter()
                .position(|n| *n == next_best)
                .unwrap_or(usize::MAX);
            if best_idx >= cur_idx {
                self.failback = None;
                // 顺序里排在当前线路之前的线路此刻不可用：它们正是「将来要回切回去」
                // 的对象，必须把它们不达标的原因交出去，否则 UI 只能显示一句
                // 「已是最优」，用户永远不知道还要不要等主线路回来。
                let waiting = waiting_for_higher(&order, &by_name, cur_idx);
                // 文案在 move 之前生成：`cur` 随后会被 `Some(cur)` 移动走。
                let reason = format!("保持活动线路 {cur}（当前已是最优可用线路）");
                return self.commit(Some(cur), &order, now_ms, reason, waiting, false);
            }
            if cfg.failback == Failback::Manual {
                let reason = format!("保持活动线路 {cur}（回切方式为手动，等待人工切换）");
                return self.commit(
                    Some(cur),
                    &order,
                    now_ms,
                    reason,
                    Some((next_best.to_string(), "failback=manual，需手动回切".into())),
                    false,
                );
            }

            let cand = by_name[next_best];
            let held = now_ms.saturating_sub(cand.state_since_ms);
            let mut missing: Vec<String> = Vec::new();
            if !cand.eligible_for_failback() {
                missing.push(format!(
                    "状态 {} 未达 HEALTHY 或预热未结束",
                    cand.state.as_str()
                ));
            }
            if held < cfg.failback_delay_ms {
                missing.push(format!("稳定时间 {held}ms < {}ms", cfg.failback_delay_ms));
            }
            if cand.consec_ok < cfg.failback_success_threshold {
                missing.push(format!(
                    "连续成功 {} < {}",
                    cand.consec_ok, cfg.failback_success_threshold
                ));
            }
            if !interval_elapsed(self.last_switch_ms, now_ms, cfg.min_switch_interval_ms) {
                missing.push(format!(
                    "距上次切换 {}ms < {}ms",
                    now_ms.saturating_sub(self.last_switch_ms),
                    cfg.min_switch_interval_ms
                ));
            }
            if !missing.is_empty() {
                // 条件不齐时不累计去抖，防止「差一点」的记录残留影响下次判断。
                self.failback = None;
                let reason = format!("保持活动线路 {cur}，等待回切 {next_best}");
                return self.commit(
                    Some(cur),
                    &order,
                    now_ms,
                    reason,
                    Some((next_best.to_string(), missing.join("、"))),
                    false,
                );
            }

            let entry = self
                .failback
                .get_or_insert_with(|| (next_best.to_string(), Debounce::new(2, 0)));
            if entry.0 != next_best {
                entry.0 = next_best.to_string();
                entry.1.reset();
            }
            if entry.1.offer(true, now_ms) {
                self.failback = None;
                return self.commit(
                    Some(next_best.to_string()),
                    &order,
                    now_ms,
                    format!("回切到 {next_best}（稳定时间、连续成功、预热、最小间隔均已满足）"),
                    None,
                    false,
                );
            }
            let reason = format!("保持活动线路 {cur}，回切 {next_best} 待二次确认");
            return self.commit(
                Some(cur),
                &order,
                now_ms,
                reason,
                Some((next_best.to_string(), "去抖二次确认中".into())),
                false,
            );
        }

        // 4) 活动线路不可用或从未选定：切到顺序里第一条可用的。
        let from = match &self.active {
            Some(a) if by_name.contains_key(a.as_str()) => {
                let r = by_name[a.as_str()]
                    .unusable_reason()
                    .unwrap_or_else(|| "状态不可用".into());
                format!("{a} 不可用（{r}），切换")
            }
            Some(a) => format!("活动线路 {a} 已从配置中消失，切换"),
            None => "首次选定活动线路".to_string(),
        };
        self.failback = None;
        let target = usable[0].to_string();
        let target_idx = order.iter().position(|n| *n == target).unwrap_or(0);
        let mut reason = format!("{from}到 {target}");
        // 被跳过的更靠前线路逐条说明原因：这是「为什么现在走的是备线」的唯一答案。
        if let Some(w) = waiting_for_higher(&order, &by_name, target_idx) {
            reason.push_str(&format!("，跳过 {}", w.1));
        }
        self.commit(Some(target.clone()), &order, now_ms, reason, None, false)
    }

    /// 写回内部状态并生成输出。`changed` 只看活动线路是否真的换了。
    fn commit(
        &mut self,
        active: Option<String>,
        order: &[String],
        now_ms: u64,
        reason: String,
        waiting: Option<(String, String)>,
        all_dead: bool,
    ) -> Decision {
        let changed = active != self.active;
        if changed {
            // 任何一次**真实**变更都刷新最小间隔计时，包含「变为不分流」：
            // 停止分流本身就是一次出口变更，恢复时应当同样受间隔保护。
            // 未变更（尤其全灭期间的 None→None）绝不刷新，否则会被自己反复
            // 刷新的计时器卡在恢复门外。
            self.last_switch_ms = now_ms;
        }
        self.active = active.clone();
        Decision {
            active,
            changed,
            reason,
            waiting,
            all_dead,
            order: order.to_vec(),
        }
    }
}

/// 顺序表中排在 `upto_idx` 之前的线路为什么还不能接回去（逐条原因）。
///
/// 返回 `None` 表示前面没有线路，或前面的线路都没有可解释的障碍。
fn waiting_for_higher(
    order: &[String],
    by_name: &BTreeMap<&str, &LineState>,
    upto_idx: usize,
) -> Option<(String, String)> {
    let mut names: Vec<String> = Vec::new();
    let mut reasons: Vec<String> = Vec::new();
    for n in order.iter().take(upto_idx) {
        let Some(l) = by_name.get(n.as_str()) else {
            continue;
        };
        if l.usable_as_active() {
            continue;
        }
        if let Some(r) = l.unusable_reason() {
            names.push(l.name.clone());
            reasons.push(format!("{}：{r}", l.name));
        }
    }
    if names.is_empty() {
        None
    } else {
        Some((names.join("、"), reasons.join("；")))
    }
}

/// 把名字加入顺序表（去重 + 必须真实存在）。
fn push_unique(out: &mut Vec<String>, lines: &[LineState], name: &str) {
    let name = name.trim();
    if name.is_empty() {
        return;
    }
    if out.iter().any(|n| n == name) {
        return;
    }
    if lines.iter().any(|l| l.name == name) {
        out.push(name.to_string());
    }
}

/// 生成主备顺序：显式主线路 → `backup_order` → 其余按槽位补齐。
pub fn order(cfg: &GlobalConfig, lines: &[LineState]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    // 1) global.primary。未填写时**不猜测**主线路是谁：直接按 backup_order、
    //    再按槽位补齐。槽位由 `system::assign_slots` 按配置顺序与 role/priority
    //    分配，因此结果仍然完全确定；校验层会就「主备模式未指定 primary」给出警告。
    if !cfg.primary.trim().is_empty() {
        push_unique(&mut out, lines, &cfg.primary);
    }
    // 2) 显式备份顺序。
    for n in &cfg.backup_order {
        push_unique(&mut out, lines, n);
    }
    // 3) 剩余线路：启用者优先，其次按槽位（= role/priority/name 的既定顺序）。
    let mut rest: Vec<&LineState> = lines.iter().filter(|l| !out.contains(&l.name)).collect();
    rest.sort_by(|a, b| {
        a.enabled
            .cmp(&b.enabled)
            .reverse()
            .then_with(|| a.slot.cmp(&b.slot))
    });
    for l in rest {
        push_unique(&mut out, lines, &l.name);
    }
    out
}

/// 顺序表是否漏掉了启用线路（`--check` 与 RPC 自检用）。
pub fn missing_from_order(cfg: &GlobalConfig, lines: &[LineState]) -> Vec<String> {
    let o = order(cfg, lines);
    lines
        .iter()
        .filter(|l| l.enabled && !o.contains(&l.name))
        .map(|l| l.name.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::Mode;

    fn line(name: &str, slot: u8, state: State) -> LineState {
        LineState {
            name: name.into(),
            slot,
            enabled: true,
            maintenance: false,
            state,
            blocked: None,
            warmup_remaining_ms: 0,
            consec_ok: 5,
            state_since_ms: 0,
        }
    }

    fn cfg() -> GlobalConfig {
        GlobalConfig {
            mode: Mode::Failover,
            primary: "wan1".into(),
            backup_order: vec!["wan2".into(), "wan3".into()],
            failback: Failback::Auto,
            failback_delay_ms: 30_000,
            failback_success_threshold: 5,
            min_switch_interval_ms: 10_000,
            ..Default::default()
        }
    }

    fn lines() -> Vec<LineState> {
        vec![
            line("wan1", 1, State::Healthy),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ]
    }

    fn slots() -> BTreeMap<String, u8> {
        [("wan1", 1u8), ("wan2", 2), ("wan3", 3)]
            .into_iter()
            .map(|(n, s)| (n.to_string(), s))
            .collect()
    }

    #[test]
    fn order_is_primary_then_explicit_backups() {
        let c = cfg();
        assert_eq!(order(&c, &lines()), vec!["wan1", "wan2", "wan3"]);
        let mut c2 = cfg();
        c2.primary = "wan2".into();
        c2.backup_order = vec!["wan1".into()];
        assert_eq!(
            order(&c2, &lines()),
            vec!["wan2", "wan1", "wan3"],
            "未列出的按槽位补齐"
        );
        let mut c3 = cfg();
        c3.primary = "nonexistent".into();
        // primary 写了不存在的名字：该条目被忽略，显式 backup_order 仍然优先。
        assert_eq!(
            order(&c3, &lines()),
            vec!["wan2", "wan3", "wan1"],
            "不存在的名字不能挤掉真实线路"
        );
        assert_eq!(missing_from_order(&c3, &lines()), Vec::<String>::new());
    }

    #[test]
    fn order_ignores_health_state() {
        // 顺序必须稳定：主线路此刻断了也不能把它挪到末尾，
        // 否则「回切」这个动作就没有参照物了。
        let c = cfg();
        let ls = vec![
            line("wan1", 1, State::Failed),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        assert_eq!(order(&c, &ls), vec!["wan1", "wan2", "wan3"]);
    }

    #[test]
    fn unknown_is_never_active() {
        let c = cfg();
        let ls = vec![
            line("wan1", 1, State::Unknown),
            line("wan2", 2, State::Healthy),
        ];
        let mut m = Machine::new();
        let d = m.decide(&c, &ls, 1000);
        assert_eq!(
            d.active.as_deref(),
            Some("wan2"),
            "未验证的主线路不能接流量"
        );
        assert!(d.reason.contains("首次选定"), "{}", d.reason);
    }

    #[test]
    fn failover_walks_down_the_order_and_records_reasons() {
        let c = cfg();
        let mut m = Machine::new();
        let ls = vec![
            line("wan1", 1, State::Failed),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = m.decide(&c, &ls, 1000);
        assert_eq!(d.active.as_deref(), Some("wan2"));
        assert!(d.changed);
        assert!(d.reason.contains("不可用"), "{}", d.reason);
        assert_eq!(
            d.standby(&ls),
            vec!["wan3".to_string()],
            "待命列表只含可用且更靠后的线路"
        );

        let ls2 = vec![
            line("wan1", 1, State::Failed),
            line("wan2", 2, State::Failed),
            line("wan3", 3, State::Degraded),
        ];
        let d2 = m.decide(&c, &ls2, 2000);
        assert_eq!(d2.active.as_deref(), Some("wan3"), "降级线路仍算可用");

        let ls3 = vec![
            line("wan1", 1, State::Failed),
            line("wan2", 2, State::Failed),
            line("wan3", 3, State::Recovering),
        ];
        let d3 = m.decide(&c, &ls3, 3000);
        assert_eq!(d3.active, None, "没有可用线路时必须停止分流");
        assert!(d3.all_dead);
        assert!(d3.reason.contains("所有线路均不可用"), "{}", d3.reason);
        assert!(d3.bucket_map(&slots(), 8).iter().all(|b| *b == 0));

        // 全灭期间反复决策不得刷新切换计时（否则恢复后被最小间隔卡住）
        let d4 = m.decide(&c, &ls3, 4000);
        assert!(!d4.changed);
        assert_eq!(m.last_switch_ms(), 3000, "None→None 不算切换");
    }

    #[test]
    fn failback_requires_every_condition_then_double_confirmation() {
        let c = cfg();
        let mut m = Machine::new();
        let bad = line("wan1", 1, State::Failed);
        let ls = vec![
            bad,
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        m.decide(&c, &ls, 1000);
        assert_eq!(m.active(), Some("wan2"));

        // ①稳定时间不足
        let mut good = line("wan1", 1, State::Healthy);
        good.state_since_ms = 40_000;
        let ls2 = vec![
            good.clone(),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = m.decide(&c, &ls2, 41_000);
        assert_eq!(d.active.as_deref(), Some("wan2"));
        assert!(
            d.waiting.as_ref().unwrap().1.contains("稳定时间"),
            "{:?}",
            d.waiting
        );

        // ②连续成功不足
        let mut g2 = line("wan1", 1, State::Healthy);
        g2.consec_ok = 2;
        let ls3 = vec![
            g2,
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = m.decide(&c, &ls3, 100_000);
        assert_eq!(d.active.as_deref(), Some("wan2"));
        assert!(
            d.waiting.as_ref().unwrap().1.contains("连续成功"),
            "{:?}",
            d.waiting
        );

        // ③预热未结束（状态为 RECOVERING）
        let mut g3 = line("wan1", 1, State::Recovering);
        g3.warmup_remaining_ms = 4_000;
        let ls4 = vec![
            g3,
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = m.decide(&c, &ls4, 200_000);
        assert_eq!(d.active.as_deref(), Some("wan2"));
        assert!(
            d.waiting.as_ref().unwrap().1.contains("预热"),
            "{:?}",
            d.waiting
        );

        // ④最小切换间隔不足：刚刚切过一次
        let mut fresh = Machine::new();
        let ls5 = vec![
            line("wan1", 1, State::Healthy),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = fresh.decide(&c, &ls5, 1_000);
        assert_eq!(d.active.as_deref(), Some("wan1"));
        // 主线路故意挂掉再回来，制造「刚切换过」的场景
        let down = vec![
            line("wan1", 1, State::Failed),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        fresh.decide(&c, &down, 2_000);
        assert_eq!(fresh.active(), Some("wan2"));
        let mut back = line("wan1", 1, State::Healthy);
        back.state_since_ms = 2_500;
        let up = vec![
            back,
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = fresh.decide(&c, &up, 3_000);
        assert_eq!(d.active.as_deref(), Some("wan2"));
        assert!(
            d.waiting.as_ref().unwrap().1.contains("距上次切换"),
            "{:?}",
            d.waiting
        );

        // 四条都满足：首次只记一次确认，第二次才真切
        let mut ok = line("wan1", 1, State::Healthy);
        ok.state_since_ms = 1_000;
        let ls6 = vec![
            ok,
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = m.decide(&c, &ls6, 300_000);
        assert_eq!(
            d.active.as_deref(),
            Some("wan2"),
            "首次满足只记确认，不立刻切换"
        );
        assert!(d.reason.contains("二次确认"), "{}", d.reason);
        let d2 = m.decide(&c, &ls6, 301_000);
        assert_eq!(d2.active.as_deref(), Some("wan1"), "二次确认后回切");
        assert!(d2.changed);
        assert!(d2.reason.contains("回切"), "{}", d2.reason);
        // 回切后不得反复 replace
        let d3 = m.decide(&c, &ls6, 302_000);
        assert!(!d3.changed, "{d3:?}");
    }

    #[test]
    fn manual_failback_never_returns_automatically() {
        let mut c = cfg();
        c.failback = Failback::Manual;
        let mut m = Machine::new();
        let ls = vec![
            line("wan1", 1, State::Failed),
            line("wan2", 2, State::Healthy),
        ];
        m.decide(&c, &ls, 1000);
        assert_eq!(m.active(), Some("wan2"));
        let good = vec![
            line("wan1", 1, State::Healthy),
            line("wan2", 2, State::Healthy),
        ];
        for t in 10..40u64 {
            let d = m.decide(&c, &good, t * 10_000);
            assert_eq!(d.active.as_deref(), Some("wan2"), "手动模式绝不自动回切");
        }
        let d = m.decide(&c, &good, 500_000);
        assert!(d.reason.contains("手动"), "{}", d.reason);
        assert!(
            d.waiting.as_ref().unwrap().1.contains("manual"),
            "{:?}",
            d.waiting
        );
        m.force("wan1");
        let d2 = m.decide(&c, &good, 501_000);
        assert_eq!(d2.active.as_deref(), Some("wan1"));
        assert!(d2.reason.contains("强制"), "{}", d2.reason);
    }

    #[test]
    fn forced_target_waits_until_it_becomes_usable() {
        let c = cfg();
        let mut m = Machine::new();
        let ls = vec![
            line("wan1", 1, State::Healthy),
            line("wan2", 2, State::Healthy),
        ];
        m.decide(&c, &ls, 1000);
        m.force("wan3");
        let with_dead = vec![
            line("wan1", 1, State::Healthy),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Failed),
        ];
        let d = m.decide(&c, &with_dead, 2000);
        assert_eq!(
            d.active.as_deref(),
            Some("wan1"),
            "强制目标不可用时不能硬切，也不能丢弃指令"
        );
        assert_eq!(m.forced(), Some("wan3"));
        let with_ok = vec![
            line("wan1", 1, State::Healthy),
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d2 = m.decide(&c, &with_ok, 3000);
        assert_eq!(d2.active.as_deref(), Some("wan3"), "强制目标恢复后立刻生效");
        m.release_forced();
        let d3 = m.decide(&c, &with_ok, 4000);
        assert_eq!(
            d3.active.as_deref(),
            Some("wan3"),
            "取消强制后保持现状，靠回切条件再决定"
        );
        assert!(d3.waiting.is_some() || d3.reason.contains("保持"), "{d3:?}");
    }

    #[test]
    fn maintenance_and_missing_target_are_explained() {
        let c = cfg();
        let mut m = Machine::new();
        let mut p = line("wan1", 1, State::Healthy);
        p.maintenance = true;
        let d = m.decide(&c, &[p.clone(), line("wan2", 2, State::Healthy)], 1000);
        assert_eq!(d.active.as_deref(), Some("wan2"));
        assert!(d.reason.contains("维护模式"), "{}", d.reason);
        let d2 = m.decide(&c, &[p, line("wan2", 2, State::Healthy)], 2000);
        assert!(!d2.changed, "重复决策不该声称变更: {d2:?}");

        // 强制到一个根本不存在的线路：必须保持原状而不是崩溃
        m.force("wan404");
        let d3 = m.decide(
            &c,
            &[
                line("wan1", 1, State::Healthy),
                line("wan2", 2, State::Healthy),
            ],
            3000,
        );
        assert_eq!(
            d3.active.as_deref(),
            Some("wan2"),
            "不存在的目标不能成为活动线路"
        );
    }

    #[test]
    fn blocked_line_is_skipped() {
        let c = cfg();
        let mut m = Machine::new();
        let mut b = line("wan1", 1, State::Healthy);
        b.blocked = Some("设备 wwan0 链路未 up".into());
        let d = m.decide(&c, &[b, line("wan2", 2, State::Healthy)], 1000);
        assert_eq!(d.active.as_deref(), Some("wan2"));
        assert!(d.reason.contains("链路未 up"), "{}", d.reason);
    }

    #[test]
    fn bucket_map_points_every_bucket_at_the_active_line() {
        let c = cfg();
        let mut m = Machine::new();
        let d = m.decide(&c, &lines(), 1000);
        assert_eq!(d.active_slot(&slots()), 1);
        assert_eq!(d.bucket_map(&slots(), 16), vec![1u8; 16]);
    }

    #[test]
    fn vanished_line_is_replaced() {
        let c = cfg();
        let mut m = Machine::new();
        m.decide(&c, &lines(), 1000);
        let rest = vec![
            line("wan2", 2, State::Healthy),
            line("wan3", 3, State::Healthy),
        ];
        let d = m.decide(&c, &rest, 1000);
        assert_eq!(
            d.active.as_deref(),
            Some("wan2"),
            "配置里删掉主线路后必须重选"
        );
        assert!(d.reason.contains("已从配置中消失"), "{}", d.reason);
    }

    #[test]
    fn order_covers_every_enabled_line() {
        let mut c = cfg();
        c.backup_order = vec![];
        c.primary = String::new();
        let extra = vec![
            line("wan5", 5, State::Healthy),
            line("wan1", 1, State::Healthy),
            line("wan2", 2, State::Healthy),
            LineState {
                name: "down".into(),
                slot: 9,
                enabled: false,
                ..line("down", 9, State::Failed)
            },
        ];
        let o = order(&c, &extra);
        assert_eq!(
            o,
            vec!["wan1", "wan2", "wan5", "down"],
            "启用者优先，停用线路仍列出但排在后面"
        );
        assert_eq!(missing_from_order(&c, &extra), Vec::<String>::new());
    }
}
