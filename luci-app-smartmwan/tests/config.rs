//! 集成测试：配置层端到端（文件 → 解析 → 校验 → 保存 → 再读 → diff）。
//!
//! 单测覆盖的是每个函数；这里串的是**用户实际的路径**：手写 UCI 文件、改一个值、
//! 存回去、再看差异清单。任何一环失真（键名映射错、未知键被丢、diff 漏字段）
//! 都会在这里露出来 —— 它们各自单测都是绿的。

use std::collections::BTreeMap;

use smartmwan::config::schema::{Algorithm, Config, Mode, WanConfig};
use smartmwan::config::{self, validate, Store};

/// 一段贴近真机的 UCI：两条线路 + 一条游戏规则 + 一个未识别的自定义键。
const UCI: &str = r#"
config smartmwan 'global'
	option enabled '1'
	option mode 'failover'
	option algorithm 'weighted_hash'
	option primary 'wan'
	option my_custom_key 'keep-me'
	list backup_order 'wan2'

config wan 'wan'
	option enabled '1'
	option device 'eth0'
	option weight '3'
	option gateway '10.0.0.1'

config wan 'wan2'
	option enabled '1'
	option device 'eth1'
	option weight '1'
	option gateway '10.0.1.1'

config game 'svc'
	option enabled '1'
	option selection 'pin'
	option pin_wan 'wan2'
	list target '203.0.113.0/24'
	list port '443'
"#;

fn write(dir: &std::path::Path, text: &str) -> std::path::PathBuf {
    let p = dir.join("smartmwan");
    std::fs::write(&p, text).unwrap();
    p
}

/// 手写的 UCI 必须解析成预期的类型化配置：UCI 键名与 Rust 字段名的映射
/// 错一处（例如 `probe_interval` → `health.interval_ms`）在单测里不一定看得出来，
/// 但用户写的配置文件立刻就对不上号。
#[test]
fn hand_written_uci_decodes_into_the_expected_config() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), UCI);
    let store = Store::load(&path).unwrap();
    let c = &store.config;

    assert!(c.global.enabled);
    assert_eq!(c.global.mode, Mode::Failover);
    assert_eq!(c.global.algorithm, Algorithm::WeightedHash);
    assert_eq!(c.global.primary, "wan");
    assert_eq!(c.global.backup_order, vec!["wan2".to_string()]);
    assert_eq!(c.wans.len(), 2);
    assert_eq!(c.wans[0].weight, 3);
    assert_eq!(c.games.len(), 1);
    assert_eq!(c.games[0].pin_wan, "wan2");
    // 校验必须放行这段配置（它本来就是合法的）。
    assert!(
        validate::validate(c).is_valid(),
        "{:?}",
        validate::validate(c).errors()
    );
}

/// 保存后**再读回来**必须一致，且未识别的键原样保留。
///
/// 未知键被静默丢弃的后果：用户（或别的脚本）写进去的东西在某次保存后消失，
/// 而界面上没有任何提示。
#[test]
fn save_preserves_unknown_keys_and_round_trips() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), UCI);
    let mut store = Store::load(&path).unwrap();
    let before = store.config.clone();

    store.save(&before).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(
        text.contains("my_custom_key") && text.contains("keep-me"),
        "未识别的键必须原样保留：\n{text}"
    );

    // 再读回来：值不能漂。
    let again = Store::load(&path).unwrap().config;
    assert_eq!(again.global.mode, before.global.mode);
    assert_eq!(again.global.primary, before.global.primary);
    assert_eq!(again.wans.len(), before.wans.len());
    assert_eq!(again.games[0].targets, before.games[0].targets);
}

/// 改一个值 → diff 必须如实报出来，且只报这一项。
///
/// diff 是「应用前变更摘要」的唯一来源：漏报一项，用户就在不知情的情况下
/// 下发了一次没看见的变更（`hash_seed` 曾经就是这样被漏掉的）。
#[test]
fn diff_reports_every_changed_field_and_nothing_else() {
    let mut a = Config::default();
    a.wans.push(WanConfig {
        name: "wan".into(),
        enabled: true,
        ..Default::default()
    });
    let mut b = a.clone();
    b.global.mode = Mode::Failover;
    // 必须挑一个与默认值不同的算法，否则「没报」其实是「没变」。
    assert_ne!(a.global.algorithm, Algorithm::FullFiveTuple);
    b.global.algorithm = Algorithm::FullFiveTuple;
    b.global.hash_seed = 0x1234;

    let changes = config::diff(&a, &b);
    let paths: Vec<&str> = changes.iter().map(|c| c.path.as_str()).collect();
    for want in ["global.mode", "global.algorithm", "global.hash_seed"] {
        assert!(
            paths.iter().any(|p| p.contains(want)),
            "diff 漏报 {want}：{paths:?}"
        );
    }
    // 反过来：没改的字段不得出现在清单里，否则摘要会淹没在噪声中。
    assert!(
        !paths.iter().any(|p| p.contains("wans")),
        "未改动的线路不该出现在 diff 里：{paths:?}"
    );
}

/// 校验要拒绝「主备模式但没指定主线路」这类组合错误，并给出可操作的提示。
#[test]
fn validate_rejects_a_failover_config_without_a_primary() {
    let mut c = Config::default();
    c.global.enabled = true;
    c.global.mode = Mode::Failover;
    c.wans.push(WanConfig {
        name: "wan".into(),
        enabled: true,
        ..Default::default()
    });
    let r = validate::validate(&c);
    assert!(!r.is_valid());
    assert!(
        r.errors().iter().any(|i| i.path.contains("primary")),
        "必须指出问题出在 primary：{:?}",
        r.errors()
    );
}

/// 默认配置必须是安全的：没启用、不改变现有路由。
///
/// 这条是「首次安装绝不能动用户的网络」的守门断言，任何把默认值改成 enabled=1
/// 的改动都会在这里红。
#[test]
fn defaults_are_safe_and_disabled() {
    let c = Config::default();
    assert!(!c.global.enabled, "默认必须停用");
    assert!(c.wans.is_empty());
    // 默认 UCI 文本也要能解析回同样的配置（安装期文件与代码必须同源）。
    let text = Store::defaults_uci_text();
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), &text);
    let back = Store::load(&path).unwrap().config;
    assert!(!back.global.enabled);
    assert_eq!(back.global.mode, c.global.mode);
}

/// 权重与槽位：线路顺序由配置决定，不能依赖 map 的迭代顺序 ——
/// 否则重启后桶会整体重排（已建立连接换出口）。
#[test]
fn line_order_is_determined_by_configuration_not_by_map_order() {
    // 场景：`uci` 命令或手工编辑都可能改变文件里**段的先后顺序**，而段顺序本身
    // 没有语义。若槽位跟着段顺序走，一次无关紧要的重写就会让桶整体重排 ——
    // 已建立的连接因此换出口。所以两次解析必须给出同样的槽位。
    let uci = |order: &[&str]| -> String {
        let mut s = String::from("config smartmwan 'global'\n\toption enabled '1'\n");
        for (i, n) in order.iter().enumerate() {
            // priority 按**名字**给，与段在文件里的先后无关：这正是要验证的前提。
            // （若 priority 跟着段顺序走，槽位变化就是配置变了，而不是顺序问题。）
            let prio = match *n {
                "wan" => 3,
                "wan2" => 2,
                _ => 1,
            };
            s.push_str(&format!(
                "\nconfig wan '{n}'\n\toption enabled '1'\n\toption device 'eth{i}'\n\toption priority '{prio}'\n"
            ));
        }
        s
    };
    let dir = tempfile::tempdir().unwrap();
    let a = Store::load(&write(dir.path(), &uci(&["wan", "wan2", "wan3"])))
        .unwrap()
        .config;
    let b = Store::load(&write(dir.path(), &uci(&["wan3", "wan2", "wan"])))
        .unwrap()
        .config;
    let norm = |m: &BTreeMap<String, u8>| {
        m.iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join(",")
    };
    let sa = smartmwan::scheduler::slot_map(&a).unwrap();
    let sb = smartmwan::scheduler::slot_map(&b).unwrap();
    assert_eq!(
        norm(&sa),
        norm(&sb),
        "槽位必须由配置顺序唯一决定，与文件里的段顺序无关"
    );
}
