//! 集成测试：规则层 → 数据面的**落地结果**。
//!
//! 单测分别验证「编译产物对不对」和「nft 文本对不对」；这里验证的是两者接起来之后
//! 用户真正关心的三件事：条件有没有出现在最终文本里、能力不足时规则有没有被
//! 悄悄放宽、命中统计是不是只数游戏规则。

use std::collections::BTreeMap;

use smartmwan::config::schema::{Config, GameRule, GameSelection, ProtoFilter, WanConfig};
use smartmwan::config::validate;
use smartmwan::rules::{self, matchers, GameHits};
use smartmwan::system::firewall::{self, Capabilities, Line, RuleInfo, TABLE};
use smartmwan::system::netlink::Family;

fn base_cfg() -> Config {
    let mut c = Config::default();
    c.global.enabled = true;
    c.global.buckets = 8;
    c.wans.push(WanConfig {
        name: "wan".into(),
        enabled: true,
        ..Default::default()
    });
    c.wans.push(WanConfig {
        name: "wan2".into(),
        enabled: true,
        ..Default::default()
    });
    c
}

fn game(name: &str) -> GameRule {
    GameRule {
        name: name.to_string(),
        enabled: true,
        selection: GameSelection::Pin,
        pin_wan: "wan2".into(),
        proto: ProtoFilter::Both,
        ..Default::default()
    }
}

/// 编译 + 生成程序：走的是守护进程真实的那条路径。
fn compile_and_build(cfg: &Config, caps: &Capabilities) -> firewall::Program {
    let slots: BTreeMap<String, u8> = [("wan".to_string(), 1), ("wan2".to_string(), 2)]
        .into_iter()
        .collect();
    let picks: BTreeMap<String, u8> = BTreeMap::new();
    let presets: Vec<smartmwan::rules::presets::Preset> = Vec::new();
    let compiled = rules::compile(&rules::Input {
        cfg,
        slots: &slots,
        gen: 0,
        caps,
        presets: &presets,
        picks: &picks,
    })
    .unwrap();

    let lines = [
        Line {
            name: "wan".into(),
            slot: 1,
        },
        Line {
            name: "wan2".into(),
            slot: 2,
        },
    ];
    let bucket_map = vec![1u8, 2, 1, 2, 1, 2, 1, 2];
    let lan = ["br-lan".to_string()];
    let empty: Vec<String> = Vec::new();
    firewall::build(&firewall::Input {
        algorithm: cfg.global.algorithm,
        buckets: cfg.global.buckets,
        bucket_map: &bucket_map,
        gen: 0,
        hash_seed: 0,
        conn_sticky: false,
        families: &[Family::V4],
        lan_ifaces: &lan,
        lines: &lines,
        games: &compiled.specs,
        protected_v4: &empty,
        protected_v6: &empty,
        bypass_v4: &empty,
        bypass_v6: &empty,
        caps,
    })
    .unwrap()
}

/// 全部能力可用时的基准能力表（其余测试在它上面关开关）。
fn full_caps() -> Capabilities {
    Capabilities {
        nft_exists: true,
        version: "1.1.7".into(),
        jhash_map: true,
        ct_mark_range: true,
        th_payload: true,
        dyn_timeout_sets: true,
        route_hook_output: true,
        ether_sets: true,
        comments: true,
        jhash_seed: false,
    }
}

/// 条件必须**出现在最终规则文本里**：只断言集合被声明过是不够的 ——
/// 历史上正是这样漏掉了整条 MAC 条件（匹配面被静默放大到全 LAN）。
#[test]
fn every_condition_really_appears_in_the_rule_text() {
    let mut cfg = base_cfg();
    let mut g = game("svc");
    g.targets = vec!["203.0.113.0/24".into()];
    g.ports = vec!["443".into()];
    g.client_ips = vec!["192.168.1.50".into()];
    g.client_macs = vec!["AA:BB:CC:DD:EE:FF".into()];
    cfg.games.push(g);
    assert!(validate::validate(&cfg).is_valid());

    let prog = compile_and_build(&cfg, &full_caps());
    let line = prog
        .text
        .lines()
        .find(|l| l.contains("smw:game:svc"))
        .expect("游戏规则必须出现在程序里")
        .to_string();
    assert!(
        line.contains("ip daddr @smw_g_svc_dst4"),
        "目的条件缺失：{line}"
    );
    assert!(
        line.contains("ip saddr @smw_g_svc_cli4"),
        "客户端条件缺失：{line}"
    );
    assert!(
        line.contains("ether saddr @smw_g_svc_mac"),
        "MAC 条件缺失：{line}"
    );
    assert!(line.contains("th dport"), "端口条件缺失：{line}");
    assert!(
        line.contains("counter"),
        "游戏规则必须带 counter（命中统计靠它）"
    );
    // 生成的脚本必须是本项目的表，绝不碰 fw4 的对象。
    assert!(prog.text.contains(&format!("table inet {TABLE}")));
    assert!(!prog.text.contains("table inet fw4"), "不得改动 fw4 的表");
}

/// 客户端条件**全部**无法生效时必须整条不下发。
///
/// 少一个条件不是「不生效」而是「匹配面变大」：只剩目的条件的规则会命中
/// 全部内网主机，比规则不生效严重一个量级。
#[test]
fn a_rule_with_no_usable_client_condition_is_not_emitted() {
    let mut cfg = base_cfg();
    let mut g = game("maconly");
    g.targets = vec!["203.0.113.0/24".into()];
    g.client_macs = vec!["AA:BB:CC:DD:EE:FF".into()];
    cfg.games.push(g);

    let mut caps = full_caps();
    caps.ether_sets = false; // 设备不支持 ether_addr 集合
    let prog = compile_and_build(&cfg, &caps);
    assert!(
        !prog.text.contains("smw:game:maconly"),
        "客户端条件无法生效时整条规则不得下发"
    );
    assert!(
        prog.issues.iter().any(|i| i.message.contains("不下发")),
        "必须告诉用户规则没下发：{:?}",
        prog.issues
    );
}

/// 域名条件不被支持时同样不许退化成「无目的条件的兜底规则」。
#[test]
fn a_domain_rule_is_dropped_when_dynamic_sets_are_unsupported() {
    let mut cfg = base_cfg();
    let mut g = game("dnsrule");
    g.domains = vec!["example.com".into()];
    cfg.games.push(g);

    let mut caps = full_caps();
    caps.dyn_timeout_sets = false;
    let prog = compile_and_build(&cfg, &caps);
    assert!(
        !prog.text.contains("smw:game:dnsrule"),
        "域名条件失效时不得下发无目的条件的兜底规则"
    );
}

/// 停用的规则不该出现在数据面上。
#[test]
fn a_disabled_rule_is_not_emitted() {
    let mut cfg = base_cfg();
    let mut g = game("off");
    g.enabled = false;
    g.targets = vec!["203.0.113.0/24".into()];
    cfg.games.push(g);
    let prog = compile_and_build(&cfg, &full_caps());
    assert!(!prog.text.contains("smw:game:off"));
}

/// 命中统计只数游戏规则：桶规则/保护/绕行的计数混进来，
/// 「命中数」就会变成「链上全部新建连接」这个别的量。
#[test]
fn hit_counts_only_count_game_rules() {
    let listing = vec![
        RuleInfo {
            handle: 1,
            comment: Some("smw:game:svc".into()),
            body: String::new(),
            packets: 10,
            bytes: 1000,
        },
        // 同一条 UCI 规则按目的条件拆成了两条 nft 规则 ⇒ 要**求和**。
        RuleInfo {
            handle: 2,
            comment: Some("smw:game:svc".into()),
            body: String::new(),
            packets: 5,
            bytes: 500,
        },
        RuleInfo {
            handle: 3,
            comment: Some("smw:bucket:3".into()),
            body: String::new(),
            packets: 999_999,
            bytes: 999_999,
        },
    ];
    let hits = GameHits::from_listing(&listing, 1234);
    assert_eq!(hits.of("svc"), Some((15, 1500)));
    assert_eq!(hits.at_ms, 1234);
    // 没查到的规则必须是 None，不能拿 0 冒充「没命中过」。
    assert_eq!(hits.of("other"), None);

    // slug 由规则段名决定：前端与后端必须按同一个规则把计数对回规则。
    assert_eq!(matchers::slug_of("svc"), "svc");
}
