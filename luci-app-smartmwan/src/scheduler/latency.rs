//! 游戏/低延迟流量的线路择优。
//!
//! # 评分公式（与文档、UI 完全一致，不允许各处各自解释）
//!
//! ```text
//! norm_rtt        = min(rtt_ms        / rtt_norm_ms,        1)
//! norm_jitter     = min(jitter_ms     / jitter_norm_ms,     1)
//! norm_loss       = min(loss_pmm      / loss_norm_pmm,      1)
//! norm_instabilit = min(instability_pmm / 1000,             1)
//!
//! score = 100
//!         - rtt_weight         * norm_rtt
//!         - jitter_weight      * norm_jitter
//!         - loss_weight        * norm_loss
//!         - instability_weight * norm_instabilit
//!         - extra_penalty            // 近期切换/预热中等附加惩罚，调用方给出
//! ```
//!
//! 钳位规则：每项归一化到 0~1，权重本身即「该项最差时扣多少分」；
//! 最终分数钳位在 0~100，因此默认权重（50/20/60/10）下最差线路为 0 分，
//! 各项都极优时为 100 分。
//!
//! # 能力边界（必须写进 UI）
//!
//! * 评分只反映**探测目标**的质量，不等于游戏服务器质量。探测目标是运营商 DNS
//!   或公共 DNS 时，到游戏服务器的实际路径可能完全不同。
//! * 样本不足（[`Metrics::confident`]）的线路不参与择优 —— 宁可保持现状，
//!   也不根据 2 个样本改命。
//! * 切换有滞回与最小稳定时间，短时间内多次跳变不会发生。

use std::collections::BTreeMap;

use crate::config::schema::ScoreWeights;
use crate::health::metrics::Metrics;
use crate::health::state::State;

use super::hysteresis::{advantage_permille, clamp_score, Debounce};

/// 一条线路的评分快照。
#[derive(Debug, Clone, PartialEq)]
pub struct Scored {
    pub name: String,
    pub slot: u8,
    pub score: f64,
    pub rtt_ms: u32,
    pub jitter_ms: u32,
    pub loss_pmm: u32,
    pub instability_pmm: u32,
    /// 状态（RECOVERING/UNKNOWN/FAILED 的线路不应进入候选）。
    pub state: State,
    /// 指标是否可信。
    pub confident: bool,
    /// 扣分明细，UI 用它解释「为什么没选这条」。
    pub deductions: Vec<(String, f64)>,
}

impl Scored {
    /// 由指标与权重算分。
    ///
    /// `extra_penalty`：调用方追加的惩罚（例如「刚发生过状态迁移」或
    /// 「该线路是备份线路且未开启游戏例外」），会被钳位到 0~100。
    pub fn evaluate(
        name: &str,
        slot: u8,
        state: State,
        m: &Metrics,
        w: &ScoreWeights,
        extra_penalty: f64,
    ) -> Scored {
        let rtt_n = ratio(m.rtt_ms as f64, w.rtt_norm_ms as f64);
        let jit_n = ratio(m.jitter_ms as f64, w.jitter_norm_ms as f64);
        // 基准为 0 表示「该项不参与扣分」：交给 ratio() 统一按 0 处理，
        // 不能再 max(1) —— 那会把「关掉某项权重」变成「该项直接扣满」。
        let loss_n = ratio(m.loss_pmm as f64, f64::from(w.loss_norm_pmm));
        let inst_n = ratio(m.instability_pmm as f64, 1000.0);
        let d_rtt = f64::from(w.rtt) * rtt_n;
        let d_jit = f64::from(w.jitter) * jit_n;
        let d_loss = f64::from(w.loss) * loss_n;
        let d_inst = f64::from(w.instability) * inst_n;
        let pen = extra_penalty.clamp(0.0, 100.0);
        let score = clamp_score(100.0 - d_rtt - d_jit - d_loss - d_inst - pen);
        Scored {
            name: name.to_string(),
            slot,
            score,
            rtt_ms: m.rtt_ms,
            jitter_ms: m.jitter_ms,
            loss_pmm: m.loss_pmm,
            instability_pmm: m.instability_pmm,
            state,
            confident: m.confident(),
            deductions: vec![
                (format!("RTT {}ms", m.rtt_ms), d_rtt),
                (format!("抖动 {}ms", m.jitter_ms), d_jit),
                (format!("丢包 {}‰", m.loss_pmm), d_loss),
                (format!("不稳定 {}‰", m.instability_pmm), d_inst),
                ("附加惩罚".into(), pen),
            ],
        }
    }

    /// 一句话说明，直接给 UI 用。
    pub fn explain(&self) -> String {
        let parts: Vec<String> = self
            .deductions
            .iter()
            .filter(|(_, v)| *v > 0.001)
            .map(|(k, v)| format!("{k} 扣 {:.1}", v))
            .collect();
        if parts.is_empty() {
            format!("{}：{:.1} 分（无明显扣分）", self.name, self.score)
        } else {
            format!(
                "{}：{:.1} 分（{}）",
                self.name,
                self.score,
                parts.join("，")
            )
        }
    }
}

/// 归一化并钳位到 0~1；基准值非法（<=0）时按 0 处理，避免除零造出 inf。
fn ratio(value: f64, norm: f64) -> f64 {
    if norm <= 0.0 || value.is_nan() {
        return 0.0;
    }
    (value / norm).clamp(0.0, 1.0)
}

/// 一次择优的结果。
#[derive(Debug, Clone, PartialEq)]
pub struct Pick {
    /// 选中的线路（`None` 表示无法决定，必须如实告诉 UI）。
    pub chosen: Option<String>,
    /// 是否本轮发生了变更（未变更时数据面不需要 replace 规则）。
    pub changed: bool,
    pub reason: String,
    /// 参与比较的全部候选评分（按分数降序）。
    pub ranking: Vec<Scored>,
}

/// 有状态的择优器：记录每条规则当前选中的线路，并执行滞回与最小稳定时间。
#[derive(Default)]
pub struct Picker {
    /// 规则名 → (线路名, 首次选定时间)。
    chosen: BTreeMap<String, (String, u64)>,
    /// 规则名 → 候选变更的去抖器。
    pending: BTreeMap<String, Debounce>,
}

impl Picker {
    pub fn new() -> Picker {
        Picker::default()
    }

    /// 当前选中项（供 RPC 展示）。
    pub fn current(&self, rule: &str) -> Option<&str> {
        self.chosen.get(rule).map(|(n, _)| n.as_str())
    }

    /// 规则被删除/停用时清理状态，避免长跑留下垃圾。
    pub fn forget(&mut self, rule: &str) {
        self.chosen.remove(rule);
        self.pending.remove(rule);
    }

    pub fn rules(&self) -> Vec<String> {
        self.chosen.keys().cloned().collect()
    }

    /// 从候选中择优。
    ///
    /// 候选必须是「此刻可用于低延迟流量」的线路（健康层已筛过），
    /// 本函数再按指标可信度筛一次，然后执行滞回。
    pub fn pick(
        &mut self,
        rule: &str,
        mut ranking: Vec<Scored>,
        w: &ScoreWeights,
        now_ms: u64,
    ) -> Pick {
        // 排序：分数降序 → 优先级稳定的名称升序，保证同样的输入永远同样的输出。
        ranking.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.name.cmp(&b.name))
        });
        let usable: Vec<Scored> = ranking
            .iter()
            .filter(|s| s.confident && matches!(s.state, State::Healthy | State::Degraded))
            .cloned()
            .collect();
        let best = match usable.first() {
            Some(b) => b.clone(),
            None => {
                return Pick {
                    chosen: self.chosen.get(rule).map(|(n, _)| n.clone()),
                    changed: false,
                    reason: if ranking.is_empty() {
                        "没有可用候选线路".to_string()
                    } else {
                        "候选线路的指标采样尚不可信，保持上一次选择".to_string()
                    },
                    ranking,
                };
            }
        };

        let current = self.chosen.get(rule).cloned();
        match &current {
            None => {
                self.chosen
                    .insert(rule.to_string(), (best.name.clone(), now_ms));
                self.pending.remove(rule);
                Pick {
                    chosen: Some(best.name.clone()),
                    changed: true,
                    reason: format!("首次选定 {}", best.explain()),
                    ranking,
                }
            }
            Some((name, since)) => {
                if *name == best.name {
                    // 最优就是当前：去抖器清零，避免累计后突然触发。
                    self.pending.remove(rule);
                    Pick {
                        chosen: Some(name.clone()),
                        changed: false,
                        reason: format!("保持 {name}（当前即为最优）"),
                        ranking,
                    }
                } else {
                    let cur_score = ranking
                        .iter()
                        .find(|s| s.name == *name)
                        .map(|s| s.score)
                        .unwrap_or(0.0);
                    let cur_state = ranking.iter().find(|s| s.name == *name).map(|s| s.state);
                    // 紧急逃离：当前线路已经不可用时，滞回与稳定时间都必须让路。
                    // 否则游戏流量会被「最小稳定时间」钉死在一条已经断掉的线路上。
                    let emergency = matches!(cur_state, Some(State::Failed) | Some(State::Unknown));
                    let adv = advantage_permille(best.score, cur_score);
                    let gap_ok = emergency
                        || cur_score <= 0.01
                        || adv >= i64::from(w.min_advantage_permille);
                    let stable_ok = emergency || now_ms.saturating_sub(*since) >= w.min_stable_ms;
                    if !gap_ok {
                        self.pending.remove(rule);
                        return Pick {
                            chosen: Some(name.clone()),
                            changed: false,
                            reason: format!(
                                "保持 {name}：候选 {} 优势 {}‰ 小于滞回 {}‰",
                                best.name, adv, w.min_advantage_permille
                            ),
                            ranking,
                        };
                    }
                    if !stable_ok {
                        return Pick {
                            chosen: Some(name.clone()),
                            changed: false,
                            reason: format!(
                                "保持 {name}：选定仅 {}ms，未达最小稳定时间 {}ms",
                                now_ms.saturating_sub(*since),
                                w.min_stable_ms
                            ),
                            ranking,
                        };
                    }
                    if emergency {
                        self.chosen
                            .insert(rule.to_string(), (best.name.clone(), now_ms));
                        self.pending.remove(rule);
                        return Pick {
                            chosen: Some(best.name.clone()),
                            changed: true,
                            reason: format!(
                                "当前线路 {name} 状态为 {}，立即改选 {}",
                                cur_state.map(|s| s.as_str()).unwrap_or("unknown"),
                                best.name
                            ),
                            ranking,
                        };
                    }
                    let d = self
                        .pending
                        .entry(rule.to_string())
                        .or_insert_with(|| Debounce::new(2, 0));
                    if d.offer(true, now_ms) {
                        self.chosen
                            .insert(rule.to_string(), (best.name.clone(), now_ms));
                        self.pending.remove(rule);
                        Pick {
                            chosen: Some(best.name.clone()),
                            changed: true,
                            reason: format!(
                                "切换到 {}（{:.1} 分，优于 {name} 的 {cur_score:.1} 分）",
                                best.name, best.score
                            ),
                            ranking,
                        }
                    } else {
                        Pick {
                            chosen: Some(name.clone()),
                            changed: false,
                            reason: format!(
                                "等待确认：候选 {} 更优，需连续满足条件后才切换",
                                best.name
                            ),
                            ranking,
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn weights() -> ScoreWeights {
        ScoreWeights::default()
    }

    fn metrics(rtt: u32, jitter: u32, loss: u32, inst: u32) -> Metrics {
        Metrics {
            samples: 20,
            ok_samples: 20,
            loss_pmm: loss,
            rtt_ms: rtt,
            min_ms: rtt.saturating_sub(5),
            max_ms: rtt + 20,
            p95_ms: rtt + 15,
            jitter_ms: jitter,
            instability_pmm: inst,
            last_ok_ms: 1000,
            last_fail_ms: 0,
            age_ms: 100,
        }
    }

    fn scored(name: &str, slot: u8, m: Metrics) -> Scored {
        Scored::evaluate(name, slot, State::Healthy, &m, &weights(), 0.0)
    }

    #[test]
    fn best_case_is_100_and_worst_is_clamped() {
        let good = Scored::evaluate(
            "g",
            1,
            State::Healthy,
            &metrics(0, 0, 0, 0),
            &weights(),
            0.0,
        );
        assert_eq!(good.score, 100.0, "{good:?}");
        let bad = Scored::evaluate(
            "b",
            2,
            State::Healthy,
            &metrics(10_000, 10_000, 1000, 1000),
            &weights(),
            50.0,
        );
        assert_eq!(bad.score, 0.0, "扣穿后必须钳到 0 而不是负数: {bad:?}");
        assert!(bad.deductions.iter().any(|(k, _)| k == "附加惩罚"));
    }

    #[test]
    fn formula_matches_spec_terms() {
        // 默认权重 rtt=50 jitter=20 loss=60 instability=10，基准 200ms/60ms/50‰
        let w = weights();
        let m = metrics(100, 30, 25, 500);
        let s = Scored::evaluate("a", 1, State::Healthy, &m, &w, 0.0);
        // 50*0.5 + 20*0.5 + 60*0.5 + 10*0.5 = 70
        assert_eq!(s.score, 30.0, "{s:?}");
        assert!(s.explain().contains("扣"), "{}", s.explain());
    }

    #[test]
    fn loss_norm_zero_does_not_divide_by_zero() {
        let mut w = weights();
        w.loss_norm_pmm = 0;
        let s = Scored::evaluate("a", 1, State::Healthy, &metrics(0, 0, 900, 0), &w, 0.0);
        assert!(s.score.is_finite(), "{s:?}");
        assert_eq!(s.score, 100.0, "基准为 0 时该项不参与扣分而不是算出 inf");
    }

    #[test]
    fn picker_requires_confident_samples() {
        let mut p = Picker::new();
        let mut m = metrics(20, 5, 0, 0);
        m.ok_samples = 2; // 不足 MIN_SAMPLES
        let r = p.pick("rule", vec![scored("wan1", 1, m.clone())], &weights(), 1000);
        assert_eq!(r.chosen, None, "采样不足时不得伪造选择");
        assert!(r.reason.contains("不可信"), "{}", r.reason);
    }

    #[test]
    fn picker_picks_best_and_holds_it() {
        let mut p = Picker::new();
        let good = scored("wanA", 1, metrics(30, 5, 0, 0));
        let bad = scored("wanB", 2, metrics(180, 50, 40, 800));
        let r = p.pick("rule", vec![bad.clone(), good.clone()], &weights(), 1000);
        assert_eq!(r.chosen.as_deref(), Some("wanA"));
        assert!(r.changed);
        assert_eq!(p.current("rule"), Some("wanA"));
        // 同一批数据再来一次：不得声称变更
        let r2 = p.pick("rule", vec![bad, good], &weights(), 2000);
        assert!(!r2.changed, "{r2:?}");
        assert_eq!(r2.chosen.as_deref(), Some("wanA"));
    }

    #[test]
    fn switching_needs_advantage_and_stability() {
        let mut w = weights();
        w.min_advantage_permille = 150;
        w.min_stable_ms = 20_000;
        let mut p = Picker::new();
        // 首次择优：wanB 85.5 分 > wanA 85 分
        let a = scored("wanA", 1, metrics(60, 10, 0, 0));
        let b = scored("wanB", 2, metrics(58, 10, 0, 0));
        let first = p.pick("rule", vec![a.clone(), b.clone()], &w, 1000);
        assert_eq!(first.chosen.as_deref(), Some("wanB"), "{first:?}");
        assert!(first.changed);

        // wanA 只反超一点（86.25 vs 85.5，约 8.8‰）：低于滞回，保持
        let a2 = scored("wanA", 1, metrics(55, 10, 0, 0));
        let hold = p.pick("rule", vec![a2, b.clone()], &w, 2000);
        assert_eq!(hold.chosen.as_deref(), Some("wanB"), "优势不足不得切换");
        assert!(hold.reason.contains("滞回"), "{}", hold.reason);

        // 明显更优（99 分，优势约 158‰），但还没到最小稳定时间
        let much_better = scored("wanA", 1, metrics(4, 2, 0, 0));
        let early = p.pick("rule", vec![much_better.clone(), b.clone()], &w, 3000);
        assert!(early.reason.contains("最小稳定时间"), "{}", early.reason);
        assert!(!early.changed);

        // 稳定时间到了，仍需连续两次确认才真的切换
        let t = 21_000;
        let wait = p.pick("rule", vec![much_better.clone(), b.clone()], &w, t);
        assert!(!wait.changed, "第一次确认不应立即切换: {wait:?}");
        assert!(wait.reason.contains("等待确认"), "{}", wait.reason);
        let sw = p.pick("rule", vec![much_better.clone(), b.clone()], &w, t + 1000);
        assert_eq!(sw.chosen.as_deref(), Some("wanA"), "{sw:?}");
        assert!(sw.changed);
    }

    #[test]
    fn current_dead_line_forces_a_switch_without_advantage_gate() {
        let mut p = Picker::new();
        let w = weights();
        let a = scored("wanA", 1, metrics(30, 5, 0, 0));
        p.pick("rule", vec![a.clone()], &w, 1000);
        // 当前线路突然死了：即使分数优势算不出来也必须离开
        let mut dead = metrics(30, 5, 0, 0);
        dead.loss_pmm = 1000;
        dead.ok_samples = 20;
        let mut a_dead = Scored::evaluate("wanA", 1, State::Failed, &dead, &w, 0.0);
        a_dead.confident = true;
        let b = scored("wanB", 2, metrics(120, 20, 10, 200));
        let r = p.pick("rule", vec![a_dead, b], &w, 2000);
        assert_eq!(r.chosen.as_deref(), Some("wanB"), "{r:?}");
        assert!(r.changed, "线路已断时必须立即逃离，不能等最小稳定时间");
        assert!(r.reason.contains("立即改选"), "{}", r.reason);
    }

    #[test]
    fn forget_clears_state() {
        let mut p = Picker::new();
        p.pick(
            "r1",
            vec![scored("a", 1, metrics(10, 1, 0, 0))],
            &weights(),
            1,
        );
        assert_eq!(p.rules(), vec!["r1".to_string()]);
        p.forget("r1");
        assert!(p.rules().is_empty());
        assert_eq!(p.current("r1"), None);
    }

    #[test]
    fn ranking_is_deterministic_and_sorted() {
        let mut p = Picker::new();
        let a = scored("wanA", 1, metrics(50, 10, 0, 0));
        let b = scored("wanB", 2, metrics(50, 10, 0, 0));
        let c = scored("wanC", 3, metrics(120, 10, 0, 0));
        let r1 = p.pick(
            "rule",
            vec![a.clone(), b.clone(), c.clone()],
            &weights(),
            1000,
        );
        p.forget("rule");
        let r2 = p.pick("rule", vec![c, b, a], &weights(), 1000);
        assert_eq!(r1.chosen, r2.chosen, "同分时必须按名称稳定选择");
        assert_eq!(r1.chosen.as_deref(), Some("wanA"), "{r1:?}");
        let names: Vec<&str> = r1.ranking.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["wanA", "wanB", "wanC"],
            "排名必须降序且顺序确定"
        );
    }
}
