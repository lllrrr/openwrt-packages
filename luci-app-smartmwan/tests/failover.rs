//! 集成测试：主备切换的**时序**。
//!
//! 单测覆盖 `Machine::decide` 的分支；这里串的是运维真正关心的场景：
//! 主线路挂了会不会切、多级备用的顺序对不对、回切是不是真的等够了条件、
//! 强制切换会不会覆盖自动决策。

use std::collections::BTreeMap;

use smartmwan::config::schema::{Config, Failback, Mode, WanConfig};
use smartmwan::health::{Metrics, Snapshot, State, WanHealth};
use smartmwan::scheduler::balancing::Load;
use smartmwan::scheduler::Scheduler;

fn wan(name: &str, priority: u16) -> WanConfig {
    WanConfig {
        name: name.to_string(),
        enabled: true,
        priority,
        ..Default::default()
    }
}

/// 构造快照：`states` 里给 (线路名, 状态)，其余字段按「已稳定很久」填写，
/// 避免被测的是预热/去抖而不是切换本身。
fn snapshot(states: &[(&str, State)], now: u64) -> Snapshot {
    let mut map = BTreeMap::new();
    for (n, st) in states {
        let healthy = *st == State::Healthy;
        map.insert(
            (*n).to_string(),
            WanHealth {
                name: (*n).to_string(),
                state: *st,
                metrics: Some(Metrics {
                    samples: 40,
                    ok_samples: if healthy { 40 } else { 0 },
                    rtt_ms: if healthy { 20 } else { 0 },
                    loss_pmm: if healthy { 0 } else { 1000 },
                    ..Default::default()
                }),
                last_outcome: Some(if healthy {
                    "reply".into()
                } else {
                    "timeout".into()
                }),
                last_transition: None,
                warmup_remaining_ms: 0,
                blocked_reason: None,
                state_since_ms: 0, // 状态已持续很久 ⇒ 稳定时间与连续成功都满足
                consec_ok: if healthy { 20 } else { 0 },
                consec_fail: if healthy { 0 } else { 20 },
                probes_total: 40,
                probes_ignored: 0,
            },
        );
    }
    Snapshot {
        wan: map,
        at_ms: now,
        measured: true,
    }
}

fn loads(names: &[&str]) -> BTreeMap<String, Load> {
    names
        .iter()
        .map(|n| {
            (
                (*n).to_string(),
                Load {
                    measured: true,
                    ..Default::default()
                },
            )
        })
        .collect()
}

/// 主备配置：主 wan，备用 wan2 → wan3（越靠前越优先）。
fn failover_cfg() -> Config {
    let mut c = Config::default();
    c.global.enabled = true;
    c.global.mode = Mode::Failover;
    c.global.primary = "wan".into();
    c.global.backup_order = vec!["wan2".into(), "wan3".into()];
    c.global.failback = Failback::Auto;
    c.global.failback_delay_ms = 0;
    c.global.failback_success_threshold = 1;
    c.global.min_switch_interval_ms = 0;
    c.wans.push(wan("wan", 3));
    c.wans.push(wan("wan2", 2));
    c.wans.push(wan("wan3", 1));
    c
}

#[test]
fn the_primary_carries_traffic_while_it_is_healthy() {
    let cfg = failover_cfg();
    let names = ["wan", "wan2", "wan3"];
    let out = Scheduler::new()
        .decide(
            &cfg,
            &snapshot(
                &[
                    ("wan", State::Healthy),
                    ("wan2", State::Healthy),
                    ("wan3", State::Healthy),
                ],
                1000,
            ),
            &loads(&names),
            1000,
        )
        .unwrap();
    assert_eq!(out.active.as_deref(), Some("wan"));
    assert!(!out.all_dead);
}

/// 主线路故障 → 切到备用列表里的**第一个**可用线路，不是随便挑一条。
#[test]
fn failover_picks_the_first_usable_backup_in_order() {
    let cfg = failover_cfg();
    let names = ["wan", "wan2", "wan3"];
    let out = Scheduler::new()
        .decide(
            &cfg,
            &snapshot(
                &[
                    ("wan", State::Failed),
                    ("wan2", State::Failed),
                    ("wan3", State::Healthy),
                ],
                1000,
            ),
            &loads(&names),
            1000,
        )
        .unwrap();
    assert_eq!(out.active.as_deref(), Some("wan3"), "应跳过不可用的 wan2");
}

/// 主线路恢复后自动回切。
#[test]
fn auto_failback_returns_to_the_primary_once_it_is_healthy_again() {
    let cfg = failover_cfg();
    let names = ["wan", "wan2", "wan3"];
    let mut s = Scheduler::new();
    // 第一步：主线路故障 → 切走。
    let out = s
        .decide(
            &cfg,
            &snapshot(
                &[
                    ("wan", State::Failed),
                    ("wan2", State::Healthy),
                    ("wan3", State::Healthy),
                ],
                1000,
            ),
            &loads(&names),
            1000,
        )
        .unwrap();
    assert_eq!(out.active.as_deref(), Some("wan2"));
    // 第二步：主线路恢复（且已稳定很久）。回切带**去抖二次确认**，
    // 第一轮只登记意向，不立刻切 —— 抖动线路不该被一次成功就接回来。
    let healthy_again = snapshot(
        &[
            ("wan", State::Healthy),
            ("wan2", State::Healthy),
            ("wan3", State::Healthy),
        ],
        2000,
    );
    let first = s
        .decide(&cfg, &healthy_again, &loads(&names), 2000)
        .unwrap();
    assert_eq!(
        first.active.as_deref(),
        Some("wan2"),
        "第一轮只登记回切意向"
    );
    assert!(
        first
            .waiting
            .as_ref()
            .map(|(_, why)| why.contains("去抖"))
            .unwrap_or(false),
        "必须说明第一轮为什么不切：{:?}",
        first.waiting
    );
    // 第二轮确认 → 真正回切。
    let out = s
        .decide(&cfg, &healthy_again, &loads(&names), 2100)
        .unwrap();
    assert_eq!(out.active.as_deref(), Some("wan"), "二次确认后应回切");
}

/// 回切条件不齐时**不切**，并且把「还差什么」交出去 ——
/// 否则界面只能显示「已是最优」，用户永远不知道还要不要等。
#[test]
fn waiting_failover_explains_what_is_still_missing() {
    let mut cfg = failover_cfg();
    cfg.global.failback_delay_ms = 60_000; // 要求稳定 60 秒
    cfg.global.failback_success_threshold = 10;
    let names = ["wan", "wan2", "wan3"];
    let mut s = Scheduler::new();
    s.decide(
        &cfg,
        &snapshot(
            &[
                ("wan", State::Failed),
                ("wan2", State::Healthy),
                ("wan3", State::Healthy),
            ],
            1000,
        ),
        &loads(&names),
        1000,
    )
    .unwrap();

    // 主线路刚恢复（state_since_ms = 2000，稳定时间不足）。
    let mut snap = snapshot(
        &[
            ("wan", State::Healthy),
            ("wan2", State::Healthy),
            ("wan3", State::Healthy),
        ],
        2000,
    );
    snap.wan.get_mut("wan").unwrap().state_since_ms = 2000;
    snap.wan.get_mut("wan").unwrap().consec_ok = 1;
    let out = s.decide(&cfg, &snap, &loads(&names), 2000).unwrap();
    assert_eq!(out.active.as_deref(), Some("wan2"), "条件不齐不得回切");
    let waiting = out.waiting.as_ref().expect("必须说明在等谁").0.clone();
    assert_eq!(waiting, "wan");
    assert!(
        !out.waiting.as_ref().unwrap().1.is_empty(),
        "必须列出还差的条件"
    );
}

/// 强制切换覆盖自动决策；取消强制后回到自动结果。
#[test]
fn forcing_a_line_overrides_the_automatic_choice() {
    let cfg = failover_cfg();
    let names = ["wan", "wan2", "wan3"];
    let healthy = snapshot(
        &[
            ("wan", State::Healthy),
            ("wan2", State::Healthy),
            ("wan3", State::Healthy),
        ],
        1000,
    );
    let mut s = Scheduler::new();
    s.force("wan3");
    let out = s.decide(&cfg, &healthy, &loads(&names), 1000).unwrap();
    assert_eq!(out.active.as_deref(), Some("wan3"), "强制目标必须生效");
    assert_eq!(s.forced(), Some("wan3"));

    s.release_forced();
    assert!(s.forced().is_none());
    // 回到自动结果同样要过回切去抖（两轮）。
    s.decide(&cfg, &healthy, &loads(&names), 2000).unwrap();
    let out = s.decide(&cfg, &healthy, &loads(&names), 2100).unwrap();
    assert_eq!(out.active.as_deref(), Some("wan"), "取消强制后回到自动决策");
}

/// 全部线路不可用：明确停止分流，不能假装还有出口。
#[test]
fn everything_down_means_no_active_line() {
    let cfg = failover_cfg();
    let names = ["wan", "wan2", "wan3"];
    let out = Scheduler::new()
        .decide(
            &cfg,
            &snapshot(
                &[
                    ("wan", State::Failed),
                    ("wan2", State::Failed),
                    ("wan3", State::Failed),
                ],
                1000,
            ),
            &loads(&names),
            1000,
        )
        .unwrap();
    assert!(out.active.is_none());
    assert!(out.all_dead);
    assert!(!out.carries_traffic());
    assert!(
        out.reason.contains("不可用"),
        "必须说明原因：{}",
        out.reason
    );
}
