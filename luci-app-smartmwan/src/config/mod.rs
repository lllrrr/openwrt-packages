//! 配置存取层：UCI 文本 ↔ 类型化模型，以及「保存 / 应用」分离与迁移。
//!
//! 关键语义（任务书第十一节）：
//! * `save()` 只写 `/etc/config/smartmwan`（用户意图），**不**触碰数据平面；
//! * `commit_applied()` 在事务成功后把生效快照写入 `state_dir/applied.json`，
//!   同时保留 `applied.json.last-good`；启动时优先加载已应用快照，
//!   使得「保存了一半的错误配置」不会让设备重启后失联；
//! * `migrate()` 就地升级历史字段名，未识别的高版本字段保留不删。

pub mod schema;
pub mod uci;
pub mod validate;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use schema::{
    Algorithm, Config, Failback, GamePolicy, GameRule, GameSelection, GlobalConfig, HealthConfig,
    Mode, ProbeProto, ProtoFilter, ScoreWeights, WanConfig, WanRole,
};
use uci::{Section, UciFile};
pub use validate::{Issue, Report, Severity};

use crate::logging::{self, Level};
use crate::{Error, Result};

/// UCI 主段类型名。
pub const T_GLOBAL: &str = "smartmwan";
pub const T_WAN: &str = "wan";
pub const T_GAME: &str = "game";
pub const T_SCORE: &str = "score";

/// 配置仓库：持有原始 AST 与类型化视图。
#[derive(Debug, Clone)]
pub struct Store {
    pub path: PathBuf,
    /// 原始 AST；保存时以它为底，避免丢注释与未知字段。
    raw: UciFile,
    pub config: Config,
    /// 解析期间发现的非致命语法问题（带行号）。
    pub parse_warnings: Vec<String>,
}

/// 变更摘要项，`apply_config` 前必须在 UI 展示。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Change {
    pub path: String,
    pub old: String,
    pub new: String,
    /// 该变更是否具有「可能断网」的风险，UI 需要二次确认。
    pub risky: bool,
}

impl Store {
    /// 从文件加载。文件不存在时返回默认配置（安装后首次运行属正常情况）。
    pub fn load(path: &Path) -> Result<Store> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(e) => {
                return Err(Error::Config(format!("读取 {} 失败: {e}", path.display())));
            }
        };
        let mut file = UciFile::default();
        if !text.trim().is_empty() {
            let (parsed, warnings) = UciFile::parse_report(&text)?;
            file = parsed;
            if !warnings.is_empty() {
                for w in &warnings {
                    logging::warn_ctx("config", "parse", w, &[]);
                }
            }
        }
        let mut migrate_notes = Vec::new();
        migrate(&mut file, &mut migrate_notes)?;
        for n in &migrate_notes {
            logging::info_ctx("config", "migrate", n, &[]);
        }
        let config = decode(&file)?;
        Ok(Store {
            path: path.to_path_buf(),
            raw: file,
            config,
            parse_warnings: warnings_of(&text),
        })
    }

    /// 校验并保存（不应用）。返回校验报告；有致命错误时**不写盘**。
    pub fn save(&mut self, cfg: &Config) -> Result<Report> {
        let report = validate::validate(cfg);
        if !report.is_valid() {
            return Err(Error::Validate(format!(
                "配置未保存：{} 个致命问题，首个为 {}",
                report.errors().len(),
                report
                    .errors()
                    .first()
                    .map(|i| format!("{}: {}", i.path, i.message))
                    .unwrap_or_default()
            )));
        }
        let rendered = encode_into(self.raw.clone(), cfg);
        let text = rendered.render();
        // 先备份再原子写：出错时用户可以立刻回退到上一版意图。
        if self.path.exists() {
            let bak = backup_path(&self.path);
            std::fs::copy(&self.path, &bak)
                .map_err(|e| Error::Config(format!("备份 {} 失败: {e}", bak.display())))?;
        }
        uci::write_atomic(&self.path, &text)?;
        self.raw = rendered;
        self.config = cfg.clone();
        Ok(report)
    }

    /// 仅渲染文本而不落盘（`diagnostics` / `--print-config` 用）。
    pub fn render(&self, cfg: &Config) -> String {
        encode_into(self.raw.clone(), cfg).render()
    }

    /// 默认配置渲染成 UCI 文本，供包安装与「恢复默认」使用。
    pub fn defaults_uci_text() -> String {
        encode_into(UciFile::default(), &Config::default()).render()
    }
}

fn warnings_of(text: &str) -> Vec<String> {
    // 加载后再取一次告警，用于 `diagnostics` 展示；解析错误已在 load() 记录。
    UciFile::parse_report(text)
        .map(|(_, w)| w)
        .unwrap_or_default()
}

fn backup_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "config".to_string());
    path.parent()
        .unwrap_or_else(|| Path::new("/etc/config"))
        .join(format!("{name}.bak"))
}

// ---------------------------------------------------------------- 迁移 ---------

/// 历史版本迁移。规则：**只重命名/补默认值，绝不删除无法识别的键**，
/// 否则降级安装的字段会永久丢失。
pub fn migrate(file: &mut UciFile, notes: &mut Vec<String>) -> Result<()> {
    let Some(global) = file.sections.iter().position(|s| s.stype == T_GLOBAL) else {
        return Ok(()); // 全新文件
    };
    let ver = file.sections[global]
        .option("config_version")
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(1);
    if ver > crate::CONFIG_SCHEMA_VERSION {
        return Err(Error::Config(format!(
            "配置版本 {ver} 高于支持的 {}",
            crate::CONFIG_SCHEMA_VERSION
        )));
    }
    if ver == crate::CONFIG_SCHEMA_VERSION {
        return Ok(());
    }

    // 逐版本前滚
    let renames: &[&[(u32, &str, &str)]] = &[
        // v1 -> v2：早期字段命名与现在不一致
        &[(1, "primary_interface", "primary")],
        &[(2, "lb_mode", "mode"), (2, "lb_algorithm", "algorithm")],
        &[(3, "failback_enabled", "failback")],
    ];
    for table in renames {
        let (from_ver, old_key, new_key) = table[0];
        if ver <= from_ver && from_ver < crate::CONFIG_SCHEMA_VERSION {
            let sec = &mut file.sections[global];
            if let Some(v) = sec.option(old_key) {
                sec.remove_key(old_key);
                sec.set_option(new_key, &v);
                notes.push(format!("迁移 v{from_ver}: {old_key} → {new_key}"));
            }
        }
    }
    // 布尔表达式的规范化：老版本 failback 用 '1'/'0'，现在是 auto/manual
    {
        let sec = &mut file.sections[global];
        if let Some(v) = sec.option("failback") {
            let norm = match v.as_str() {
                "1" | "yes" | "true" => Some("auto"),
                "0" | "no" | "false" => Some("manual"),
                _ => None,
            };
            if let Some(n) = norm {
                sec.set_option("failback", n);
                notes.push(format!("迁移: failback `{v}` → `{n}`"));
            }
        }
    }
    file.sections[global].set_option("config_version", &crate::CONFIG_SCHEMA_VERSION.to_string());
    notes.push(format!("配置版本 {ver} → {}", crate::CONFIG_SCHEMA_VERSION));
    Ok(())
}

// ------------------------------------------------------------ 解码（读） -------

/// 读取一个必填标量，缺失时返回该字段的默认值字符串（由调用方给出）。
fn opt(sec: &Section, key: &str) -> Option<String> {
    sec.option(key).filter(|v| !v.trim().is_empty())
}

fn boolean(sec: &Section, key: &str, default: bool) -> bool {
    match opt(sec, key) {
        None => default,
        Some(v) => match v.trim().to_ascii_lowercase().as_str() {
            "1" | "yes" | "on" | "true" | "enabled" => true,
            "0" | "no" | "off" | "false" | "disabled" => false,
            // 无法识别时按默认值处理，但必须留下记录（不静默）。
            other => {
                logging::warn_ctx(
                    "config",
                    "decode",
                    &format!("{key}=`{other}` 不是合法布尔值，按默认 {default} 处理"),
                    &[],
                );
                default
            }
        },
    }
}

fn number<T>(sec: &Section, key: &str, default: T) -> T
where
    T: std::str::FromStr + Copy,
    T::Err: std::fmt::Debug,
{
    match opt(sec, key) {
        None => default,
        Some(v) => match v.trim().parse::<T>() {
            Ok(n) => n,
            Err(e) => {
                logging::warn_ctx(
                    "config",
                    "decode",
                    &format!("{key}=`{v}` 解析失败（{e:?}），按默认值处理"),
                    &[],
                );
                default
            }
        },
    }
}

/// 枚举解码：非法值必须产生错误而不是猜测，否则 UI 显示与实际策略会不一致。
fn enumerated<T: Copy>(
    sec: &Section,
    key: &str,
    default: T,
    parse: fn(&str) -> Option<T>,
) -> Result<T> {
    match opt(sec, key) {
        None => Ok(default),
        Some(v) => parse(&v).ok_or_else(|| {
            Error::Validate(format!(
                "{key} 的值 `{v}` 无法识别；合法值见 LuCI 页面提示或 docs/configuration.md"
            ))
        }),
    }
}

fn decode_health(sec: &Section, base: &HealthConfig) -> HealthConfig {
    HealthConfig {
        interval_ms: number(sec, "probe_interval", base.interval_ms),
        timeout_ms: number(sec, "probe_timeout", base.timeout_ms),
        failure_threshold: number(sec, "failure_threshold", base.failure_threshold),
        recovery_threshold: number(sec, "recovery_threshold", base.recovery_threshold),
        warmup_ms: number(sec, "recover_warmup_ms", base.warmup_ms),
        degraded_rtt_ms: number(sec, "degraded_rtt_ms", base.degraded_rtt_ms),
        degraded_loss_pmm: number(sec, "degraded_loss_pmm", base.degraded_loss_pmm),
        degraded_jitter_ms: number(sec, "degraded_jitter_ms", base.degraded_jitter_ms),
        max_concurrent_probes: number(sec, "max_concurrent_probes", base.max_concurrent_probes),
    }
}

fn decode_global(sec: &Section) -> Result<GlobalConfig> {
    let d = GlobalConfig::default();
    Ok(GlobalConfig {
        config_version: number(sec, "config_version", d.config_version),
        enabled: boolean(sec, "enabled", d.enabled),
        mode: enumerated(sec, "mode", d.mode, Mode::parse)?,
        algorithm: enumerated(sec, "algorithm", d.algorithm, Algorithm::parse)?,
        game_policy: enumerated(sec, "game_policy", d.game_policy, GamePolicy::parse)?,
        failback: enumerated(sec, "failback", d.failback, Failback::parse)?,
        primary: opt(sec, "primary").unwrap_or_default(),
        backup_order: sec.list("backup_order"),
        failback_delay_ms: number(sec, "failback_delay_ms", d.failback_delay_ms),
        failback_success_threshold: number(
            sec,
            "failback_success_threshold",
            d.failback_success_threshold,
        ),
        min_switch_interval_ms: number(sec, "min_switch_interval_ms", d.min_switch_interval_ms),
        conn_sticky: boolean(sec, "conn_sticky", d.conn_sticky),
        hash_seed: number(sec, "hash_seed", d.hash_seed),
        buckets: number(sec, "buckets", d.buckets),
        health: decode_health(sec, &d.health),
        sample_window_ms: number(sec, "sample_window_ms", d.sample_window_ms),
        rebalance_interval_ms: number(sec, "rebalance_interval_ms", d.rebalance_interval_ms),
        smoothing_permille: number(sec, "smoothing_permille", d.smoothing_permille),
        max_connections_per_wan: number(sec, "max_connections_per_wan", d.max_connections_per_wan),
        protected_src: sec.list("protected_src"),
        bypass_dst: if sec.list("bypass_dst").is_empty() {
            d.bypass_dst
        } else {
            sec.list("bypass_dst")
        },
        lan_zones: if sec.list("lan_zone").is_empty() {
            d.lan_zones
        } else {
            sec.list("lan_zone")
        },
        enable_ipv6: boolean(sec, "enable_ipv6", d.enable_ipv6),
        log_level: opt(sec, "log_level").unwrap_or(d.log_level),
        log_file: opt(sec, "log_file").unwrap_or(d.log_file),
        log_max_bytes: number(sec, "log_max_bytes", d.log_max_bytes),
        log_keep_backups: number(sec, "log_keep_backups", d.log_keep_backups),
        rpc_socket: opt(sec, "rpc_socket").unwrap_or(d.rpc_socket),
        state_dir: opt(sec, "state_dir").unwrap_or(d.state_dir),
        require_confirm: boolean(sec, "require_confirm", d.require_confirm),
        dns_ttl_floor_s: number(sec, "dns_ttl_floor_s", d.dns_ttl_floor_s),
    })
}

fn decode_wan(sec: &Section, global_health: &HealthConfig) -> Result<WanConfig> {
    let d = WanConfig::default();
    let name = sec
        .name
        .clone()
        .ok_or_else(|| Error::Validate("config wan 段必须具名（段名即线路标识）".into()))?;
    Ok(WanConfig {
        name,
        enabled: boolean(sec, "enabled", d.enabled),
        role: enumerated(sec, "role", d.role, WanRole::parse)?,
        device: opt(sec, "device").unwrap_or_default(),
        weight: number(sec, "weight", d.weight),
        priority: number(sec, "priority", d.priority),
        down_kbps: number(sec, "down_kbps", d.down_kbps),
        up_kbps: number(sec, "up_kbps", d.up_kbps),
        probe_targets: sec.list("probe_target"),
        probe_proto: enumerated(sec, "probe_proto", d.probe_proto, ProbeProto::parse)?,
        probe_port: number(sec, "probe_port", d.probe_port),
        probe_ipv6: boolean(sec, "probe_ipv6", d.probe_ipv6),
        gateway: opt(sec, "gateway").unwrap_or_default(),
        src_ip: opt(sec, "src_ip").unwrap_or_default(),
        maintenance: boolean(sec, "maintenance", d.maintenance),
        health: decode_health(sec, global_health),
        label: opt(sec, "label").unwrap_or_default(),
    })
}

fn decode_game(sec: &Section) -> Result<GameRule> {
    let d = GameRule::default();
    let name = sec.name.clone().ok_or_else(|| {
        Error::Validate("config game 段必须具名（用于规则定位与冲突提示）".into())
    })?;
    Ok(GameRule {
        name,
        enabled: boolean(sec, "enabled", d.enabled),
        priority: number(sec, "priority", d.priority),
        preset: opt(sec, "preset").unwrap_or_default(),
        targets: sec.list("target"),
        ports: sec.list("port"),
        proto: enumerated(sec, "proto", d.proto, ProtoFilter::parse)?,
        client_ips: sec.list("client_ip"),
        client_macs: sec.list("client_mac"),
        domains: sec.list("domain"),
        selection: enumerated(sec, "selection", d.selection, GameSelection::parse)?,
        pin_wan: opt(sec, "pin_wan").unwrap_or_default(),
        comment: opt(sec, "comment").unwrap_or_default(),
    })
}

fn decode_score(sec: &Section) -> ScoreWeights {
    let d = ScoreWeights::default();
    ScoreWeights {
        rtt: number(sec, "rtt_weight", d.rtt),
        jitter: number(sec, "jitter_weight", d.jitter),
        loss: number(sec, "loss_weight", d.loss),
        instability: number(sec, "instability_penalty", d.instability),
        rtt_norm_ms: number(sec, "rtt_norm_ms", d.rtt_norm_ms),
        jitter_norm_ms: number(sec, "jitter_norm_ms", d.jitter_norm_ms),
        loss_norm_pmm: number(sec, "loss_norm_pmm", d.loss_norm_pmm),
        min_advantage_permille: number(sec, "min_advantage_permille", d.min_advantage_permille),
        min_stable_ms: number(sec, "min_stable_ms", d.min_stable_ms),
    }
}

/// UCI AST → 类型化配置。枚举值非法会直接返回错误（见 [`enumerated`]）。
pub fn decode(file: &UciFile) -> Result<Config> {
    let mut cfg = Config::default();
    if let Some(sec) = file.section(T_GLOBAL, "global") {
        cfg.global = decode_global(sec)?;
    }
    for sec in file.sections_of(T_WAN) {
        cfg.wans.push(decode_wan(sec, &cfg.global.health)?);
    }
    for sec in file.sections_of(T_GAME) {
        cfg.games.push(decode_game(sec)?);
    }
    if let Some(sec) = file.section(T_SCORE, "default") {
        cfg.score = decode_score(sec);
    }
    // 保持线路顺序稳定：按 priority、名称排序，避免 UCI 顺序变化导致桶重排。
    cfg.wans.sort_by(|a, b| {
        a.priority
            .cmp(&b.priority)
            .then_with(|| a.name.cmp(&b.name))
    });
    cfg.games.sort_by(|a, b| {
        a.priority
            .cmp(&b.priority)
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(cfg)
}

// ------------------------------------------------------------ 编码（写） -------

fn encode_global(sec: &mut Section, g: &GlobalConfig) {
    sec.set_option("config_version", &g.config_version.to_string());
    sec.set_option("enabled", if g.enabled { "1" } else { "0" });
    sec.set_option("mode", g.mode.as_str());
    sec.set_option("algorithm", g.algorithm.as_str());
    sec.set_option("game_policy", g.game_policy.as_str());
    sec.set_option("failback", g.failback.as_str());
    set_or_clear(sec, "primary", &g.primary);
    sec.set_list("backup_order", &g.backup_order);
    sec.set_option("failback_delay_ms", &g.failback_delay_ms.to_string());
    sec.set_option(
        "failback_success_threshold",
        &g.failback_success_threshold.to_string(),
    );
    sec.set_option(
        "min_switch_interval_ms",
        &g.min_switch_interval_ms.to_string(),
    );
    sec.set_option("conn_sticky", if g.conn_sticky { "1" } else { "0" });
    sec.set_option("hash_seed", &g.hash_seed.to_string());
    sec.set_option("buckets", &g.buckets.to_string());
    encode_health(sec, &g.health);
    sec.set_option("sample_window_ms", &g.sample_window_ms.to_string());
    sec.set_option(
        "rebalance_interval_ms",
        &g.rebalance_interval_ms.to_string(),
    );
    sec.set_option("smoothing_permille", &g.smoothing_permille.to_string());
    sec.set_option(
        "max_connections_per_wan",
        &g.max_connections_per_wan.to_string(),
    );
    sec.set_list("protected_src", &g.protected_src);
    sec.set_list("bypass_dst", &g.bypass_dst);
    sec.set_list("lan_zone", &g.lan_zones);
    sec.set_option("enable_ipv6", if g.enable_ipv6 { "1" } else { "0" });
    sec.set_option("log_level", &g.log_level);
    sec.set_option("log_file", &g.log_file);
    sec.set_option("log_max_bytes", &g.log_max_bytes.to_string());
    sec.set_option("log_keep_backups", &g.log_keep_backups.to_string());
    sec.set_option("rpc_socket", &g.rpc_socket);
    sec.set_option("state_dir", &g.state_dir);
    sec.set_option("require_confirm", if g.require_confirm { "1" } else { "0" });
    sec.set_option("dns_ttl_floor_s", &g.dns_ttl_floor_s.to_string());
}

fn encode_health(sec: &mut Section, h: &HealthConfig) {
    sec.set_option("probe_interval", &h.interval_ms.to_string());
    sec.set_option("probe_timeout", &h.timeout_ms.to_string());
    sec.set_option("failure_threshold", &h.failure_threshold.to_string());
    sec.set_option("recovery_threshold", &h.recovery_threshold.to_string());
    sec.set_option("recover_warmup_ms", &h.warmup_ms.to_string());
    sec.set_option("degraded_rtt_ms", &h.degraded_rtt_ms.to_string());
    sec.set_option("degraded_loss_pmm", &h.degraded_loss_pmm.to_string());
    sec.set_option("degraded_jitter_ms", &h.degraded_jitter_ms.to_string());
    sec.set_option(
        "max_concurrent_probes",
        &h.max_concurrent_probes.to_string(),
    );
}

fn encode_wan(sec: &mut Section, w: &WanConfig) {
    sec.set_option("enabled", if w.enabled { "1" } else { "0" });
    sec.set_option("role", w.role.as_str());
    set_or_clear(sec, "device", &w.device);
    sec.set_option("weight", &w.weight.to_string());
    sec.set_option("priority", &w.priority.to_string());
    sec.set_option("down_kbps", &w.down_kbps.to_string());
    sec.set_option("up_kbps", &w.up_kbps.to_string());
    sec.set_list("probe_target", &w.probe_targets);
    sec.set_option("probe_proto", w.probe_proto.as_str());
    sec.set_option("probe_port", &w.probe_port.to_string());
    sec.set_option("probe_ipv6", if w.probe_ipv6 { "1" } else { "0" });
    set_or_clear(sec, "gateway", &w.gateway);
    set_or_clear(sec, "src_ip", &w.src_ip);
    sec.set_option("maintenance", if w.maintenance { "1" } else { "0" });
    set_or_clear(sec, "label", &w.label);
    // 线路级检测参数只在显式覆盖时写入，避免把全局默认刷进每条线路。
    encode_health(sec, &w.health);
}

fn encode_game(sec: &mut Section, r: &GameRule) {
    sec.set_option("enabled", if r.enabled { "1" } else { "0" });
    sec.set_option("priority", &r.priority.to_string());
    set_or_clear(sec, "preset", &r.preset);
    sec.set_list("target", &r.targets);
    sec.set_list("port", &r.ports);
    sec.set_option("proto", r.proto.as_str());
    sec.set_list("client_ip", &r.client_ips);
    sec.set_list("client_mac", &r.client_macs);
    sec.set_list("domain", &r.domains);
    sec.set_option("selection", r.selection.as_str());
    set_or_clear(sec, "pin_wan", &r.pin_wan);
    set_or_clear(sec, "comment", &r.comment);
}

fn encode_score(sec: &mut Section, s: &ScoreWeights) {
    sec.set_option("rtt_weight", &s.rtt.to_string());
    sec.set_option("jitter_weight", &s.jitter.to_string());
    sec.set_option("loss_weight", &s.loss.to_string());
    sec.set_option("instability_penalty", &s.instability.to_string());
    sec.set_option("rtt_norm_ms", &s.rtt_norm_ms.to_string());
    sec.set_option("jitter_norm_ms", &s.jitter_norm_ms.to_string());
    sec.set_option("loss_norm_pmm", &s.loss_norm_pmm.to_string());
    sec.set_option(
        "min_advantage_permille",
        &s.min_advantage_permille.to_string(),
    );
    sec.set_option("min_stable_ms", &s.min_stable_ms.to_string());
}

fn set_or_clear(sec: &mut Section, key: &str, value: &str) {
    if value.is_empty() {
        sec.remove_key(key);
    } else {
        sec.set_option(key, value);
    }
}

/// 把类型化配置写回 AST（以既有 AST 为底，保留注释与未知字段），
/// 并删除本次不再存在的 wan/game 段。
pub fn encode_into(mut file: UciFile, cfg: &Config) -> UciFile {
    // global
    match file
        .sections
        .iter_mut()
        .find(|s| s.stype == T_GLOBAL && s.name.as_deref() == Some("global"))
    {
        Some(sec) => encode_global(sec, &cfg.global),
        None => {
            let mut sec = Section {
                stype: T_GLOBAL.to_string(),
                name: Some("global".into()),
                entries: Vec::new(),
            };
            encode_global(&mut sec, &cfg.global);
            file.sections.insert(0, sec);
        }
    }
    // score
    match file.sections.iter_mut().find(|s| s.stype == T_SCORE) {
        Some(sec) => encode_score(sec, &cfg.score),
        None => {
            let mut sec = Section {
                stype: T_SCORE.to_string(),
                name: Some("default".into()),
                entries: Vec::new(),
            };
            encode_score(&mut sec, &cfg.score);
            file.sections.push(sec);
        }
    }
    // wan/game：按名称匹配既有段（保序保注释），缺少的追加，多余删除
    let wan_items: Vec<(String, &WanConfig)> =
        cfg.wans.iter().map(|w| (w.name.clone(), w)).collect();
    sync_sections(&mut file, T_WAN, &wan_items, &mut |sec, w| {
        encode_wan(sec, w)
    });
    let game_items: Vec<(String, &GameRule)> =
        cfg.games.iter().map(|g| (g.name.clone(), g)).collect();
    sync_sections(&mut file, T_GAME, &game_items, &mut |sec, g| {
        encode_game(sec, g)
    });
    file
}

/// 泛型化的段同步：
/// 1. 删除该类型下名称不在新列表中的段（含匿名段，避免残留旧线路）；
/// 2. 已存在同名段就地更新，从而保留段位置与段前注释；
/// 3. 新出现的段追加到文件尾部。
///
/// `encode` 只负责写自己的字段，未识别的用户自定义字段由 `encode_*`
/// 之外的条目自然保留（`Section::set_option` 是就地替换而非重建）。
fn sync_sections<T>(
    file: &mut UciFile,
    stype: &str,
    items: &[(String, &T)],
    encode: &mut dyn FnMut(&mut Section, &T),
) {
    let names: Vec<&str> = items.iter().map(|(n, _)| n.as_str()).collect();
    file.sections.retain(|s| {
        if s.stype != stype {
            return true;
        }
        match s.name.as_deref() {
            Some(n) => names.contains(&n),
            None => false,
        }
    });
    for (name, item) in items {
        match file
            .sections
            .iter_mut()
            .find(|s| s.stype == stype && s.name.as_deref() == Some(name.as_str()))
        {
            Some(sec) => encode(sec, item),
            None => {
                let mut sec = Section {
                    stype: stype.to_string(),
                    name: Some(name.clone()),
                    entries: Vec::new(),
                };
                encode(&mut sec, item);
                file.sections.push(sec);
            }
        }
    }
}

/// 已应用快照（用于「保存 ≠ 应用」的分离与重启恢复）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Applied {
    /// FNV-1a 指纹，仅用于变更检测，不做安全用途。
    pub fingerprint: String,
    pub applied_at_ms: u64,
    pub config: Config,
    /// 应用时的事务 ID，便于把内核规则与日志关联起来。
    pub transaction: String,
}

impl Store {
    pub fn applied_path(state_dir: &Path) -> PathBuf {
        state_dir.join("applied.json")
    }

    /// 读取已应用快照；不存在或损坏时返回 `None`（调用方回落到 UCI 配置）。
    pub fn load_applied(state_dir: &Path) -> Option<Applied> {
        let p = Self::applied_path(state_dir);
        let text = std::fs::read_to_string(&p).ok()?;
        match serde_json::from_str::<Applied>(&text) {
            Ok(a) => Some(a),
            Err(e) => {
                logging::error_ctx(
                    "config",
                    "load_applied",
                    Error::Config(format!("已应用快照损坏: {e}")),
                    &[("path", p.display().to_string())],
                );
                None
            }
        }
    }

    /// 写入快照，同时维护 `.last-good`（上一次成功应用的配置）。
    pub fn store_applied(state_dir: &Path, cfg: &Config, transaction: &str) -> Result<Applied> {
        std::fs::create_dir_all(state_dir)
            .map_err(|e| Error::Config(format!("无法创建状态目录 {}: {e}", state_dir.display())))?;
        let p = Self::applied_path(state_dir);
        if p.exists() {
            std::fs::copy(&p, format!("{}.last-good", p.display()))
                .map_err(|e| Error::Config(format!("备份已应用快照失败: {e}")))?;
        }
        let a = Applied {
            fingerprint: fingerprint(cfg),
            applied_at_ms: logging::now_ms(),
            config: cfg.clone(),
            transaction: transaction.to_string(),
        };
        let text = serde_json::to_string_pretty(&a)?;
        uci::write_atomic(&p, &text)?;
        Ok(a)
    }

    /// 回滚到上一次已知良好的快照。返回 `None` 表示没有可回退的历史。
    pub fn restore_last_good(state_dir: &Path) -> Result<Option<Config>> {
        let p = Self::applied_path(state_dir);
        let lg = format!("{}.last-good", p.display());
        match std::fs::read_to_string(&lg) {
            Ok(text) => {
                let a: Applied = serde_json::from_str(&text)?;
                Ok(Some(a.config))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::Config(format!("读取 {lg} 失败: {e}"))),
        }
    }
}

/// 配置指纹（非加密）：用于判断「已保存但尚未应用」以及幂等 apply。
pub fn fingerprint(cfg: &Config) -> String {
    // 排序后的 JSON（serde_json 的 Map 顺序不稳定，这里用 pretty + 关键字段路径排序）
    let json = serde_json::to_string(cfg).unwrap_or_default();
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in json.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100_0000_01b3);
    }
    // 附加长度，降低人为构造碰撞的概率（不是安全属性）
    format!("{:016x}-{:08x}", h, json.len())
}

/// 变更摘要：逐字段比较，标出风险项。UI 在 apply 前必须展示这份列表。
pub fn diff(old: &Config, new: &Config) -> Vec<Change> {
    let mut out = Vec::new();
    let mut cmp = |path: &str, a: String, b: String, risky: bool| {
        if a != b {
            out.push(Change {
                path: path.to_string(),
                old: a,
                new: b,
                risky,
            });
        }
    };

    cmp(
        "global.enabled",
        old.global.enabled.to_string(),
        new.global.enabled.to_string(),
        true, // 打开总开关会立刻改变数据平面
    );
    cmp(
        "global.mode",
        old.global.mode.as_str().into(),
        new.global.mode.as_str().into(),
        true,
    );
    cmp(
        "global.algorithm",
        old.global.algorithm.as_str().into(),
        new.global.algorithm.as_str().into(),
        false,
    );
    cmp(
        "global.game_policy",
        old.global.game_policy.as_str().into(),
        new.global.game_policy.as_str().into(),
        false,
    );
    cmp(
        "global.primary",
        old.global.primary.clone(),
        new.global.primary.clone(),
        true,
    );
    cmp(
        "global.backup_order",
        old.global.backup_order.join(","),
        new.global.backup_order.join(","),
        true,
    );
    cmp(
        "global.enable_ipv6",
        old.global.enable_ipv6.to_string(),
        new.global.enable_ipv6.to_string(),
        true,
    );
    cmp(
        "global.lan_zones",
        old.global.lan_zones.join(","),
        new.global.lan_zones.join(","),
        true,
    );
    cmp(
        "global.protected_src",
        old.global.protected_src.join(","),
        new.global.protected_src.join(","),
        true, // 缩小保护范围有失联风险
    );
    cmp(
        "global.conn_sticky",
        old.global.conn_sticky.to_string(),
        new.global.conn_sticky.to_string(),
        true,
    );
    cmp(
        "global.buckets",
        old.global.buckets.to_string(),
        new.global.buckets.to_string(),
        false,
    );
    // 改 seed 会重排全部新建连接的落线，必须在应用前的变更清单里看得见；
    // 它不改变「能不能上网」，所以不算高风险项。
    cmp(
        "global.hash_seed",
        old.global.hash_seed.to_string(),
        new.global.hash_seed.to_string(),
        false,
    );
    cmp(
        "global.dns_ttl_floor_s",
        old.global.dns_ttl_floor_s.to_string(),
        new.global.dns_ttl_floor_s.to_string(),
        false,
    );
    cmp(
        "global.require_confirm",
        old.global.require_confirm.to_string(),
        new.global.require_confirm.to_string(),
        true,
    );

    // 线路增删与属性变化
    for w in &new.wans {
        match old.wan(&w.name) {
            None => out.push(Change {
                path: format!("wan[{}]", w.name),
                old: "(不存在)".into(),
                new: format!("enabled={} role={}", w.enabled, w.role.as_str()),
                risky: true,
            }),
            Some(o) => {
                if o.enabled != w.enabled {
                    cmp_wan(
                        &mut out,
                        &w.name,
                        "enabled",
                        o.enabled.to_string(),
                        w.enabled.to_string(),
                        true,
                    );
                }
                if o.role != w.role {
                    cmp_wan(
                        &mut out,
                        &w.name,
                        "role",
                        o.role.as_str().into(),
                        w.role.as_str().into(),
                        true,
                    );
                }
                if o.weight != w.weight {
                    cmp_wan(
                        &mut out,
                        &w.name,
                        "weight",
                        o.weight.to_string(),
                        w.weight.to_string(),
                        false,
                    );
                }
                if o.priority != w.priority {
                    cmp_wan(
                        &mut out,
                        &w.name,
                        "priority",
                        o.priority.to_string(),
                        w.priority.to_string(),
                        false,
                    );
                }
                if o.probe_targets != w.probe_targets {
                    cmp_wan(
                        &mut out,
                        &w.name,
                        "probe_target",
                        o.probe_targets.join(","),
                        w.probe_targets.join(","),
                        false,
                    );
                }
                if o.device != w.device {
                    cmp_wan(
                        &mut out,
                        &w.name,
                        "device",
                        o.device.clone(),
                        w.device.clone(),
                        true,
                    );
                }
            }
        }
    }
    for o in &old.wans {
        if new.wan(&o.name).is_none() {
            out.push(Change {
                path: format!("wan[{}]", o.name),
                old: "存在".into(),
                new: "(删除)".into(),
                risky: true,
            });
        }
    }

    // 游戏规则
    for g in &new.games {
        match old.games.iter().find(|x| x.name == g.name) {
            None => out.push(Change {
                path: format!("game[{}]", g.name),
                old: "(不存在)".into(),
                new: format!("targets={} ports={}", g.targets.len(), g.ports.len()),
                risky: false,
            }),
            Some(o) => {
                if o.targets != g.targets {
                    out.push(Change {
                        path: format!("game[{}].target", g.name),
                        old: o.targets.join(","),
                        new: g.targets.join(","),
                        risky: false,
                    });
                }
                if o.enabled != g.enabled || o.priority != g.priority {
                    out.push(Change {
                        path: format!("game[{}]", g.name),
                        old: format!("enabled={} priority={}", o.enabled, o.priority),
                        new: format!("enabled={} priority={}", g.enabled, g.priority),
                        risky: false,
                    });
                }
            }
        }
    }
    for o in &old.games {
        if !new.games.iter().any(|x| x.name == o.name) {
            out.push(Change {
                path: format!("game[{}]", o.name),
                old: "存在".into(),
                new: "(删除)".into(),
                risky: false,
            });
        }
    }

    out
}

fn cmp_wan(out: &mut Vec<Change>, name: &str, field: &str, old: String, new: String, risky: bool) {
    out.push(Change {
        path: format!("wan[{name}].{field}"),
        old,
        new,
        risky,
    });
}

/// 把日志等级同步到 logging（apply 后调用）。
pub fn apply_logging(cfg: &Config) {
    let level = Level::parse(&cfg.global.log_level).unwrap_or(Level::Info);
    let path = if cfg.global.log_file.is_empty() {
        None
    } else {
        Some(Path::new(&cfg.global.log_file))
    };
    logging::init(
        level,
        path,
        cfg.global.log_max_bytes,
        cfg.global.log_keep_backups,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_cfg() -> Config {
        let mut c = Config::default();
        c.global.enabled = true;
        c.global.mode = Mode::Failover;
        c.global.primary = "wan".into();
        c.global.backup_order = vec!["wan2".into()];
        c.wans = vec![
            WanConfig {
                name: "wan".into(),
                priority: 10,
                weight: 4,
                probe_targets: vec!["1.1.1.1".into()],
                ..Default::default()
            },
            WanConfig {
                name: "wan2".into(),
                priority: 20,
                weight: 1,
                probe_targets: vec!["9.9.9.9".into(), "8.8.8.8".into()],
                ..Default::default()
            },
        ];
        c.games.push(GameRule {
            name: "mygame".into(),
            targets: vec!["203.0.113.0/24".into()],
            ports: vec!["8000-8010".into()],
            proto: ProtoFilter::Udp,
            client_macs: vec!["aa:bb:cc:dd:ee:ff".into()],
            ..Default::default()
        });
        c
    }

    #[test]
    fn encode_decode_roundtrip_is_lossless() {
        let cfg = sample_cfg();
        let file = encode_into(UciFile::default(), &cfg);
        let text = file.render();
        let back = decode(&UciFile::parse(&text).unwrap()).unwrap();
        assert_eq!(cfg.global, back.global, "全局配置必须无损往返");
        assert_eq!(cfg.wans, back.wans, "线路配置必须无损往返");
        assert_eq!(cfg.games, back.games, "游戏规则必须无损往返");
        assert_eq!(cfg.score, back.score);
    }

    #[test]
    fn text_is_human_readable_uci() {
        let text = Store::defaults_uci_text();
        assert!(text.contains("config smartmwan 'global'"));
        assert!(text.contains("\toption enabled '0'"));
        assert!(text.contains("\tlist bypass_dst '224.0.0.0/4'"));
        // 必须能被 libuci 的常见工具读回（至少我们的解析器）
        UciFile::parse(&text).unwrap();
    }

    #[test]
    fn unknown_keys_and_comments_survive_save() {
        let raw = "# 我的备注\nconfig smartmwan 'global'\n\toption enabled '0'\n\toption future_option '保留我'\n";
        let mut file = UciFile::parse(raw).unwrap();
        let cfg = sample_cfg();
        file = encode_into(file, &cfg);
        let text = file.render();
        assert!(text.contains("future_option"), "未知字段必须保留:\n{text}");
        assert!(text.contains("我的备注"));
        assert!(text.contains("option mode 'failover'"));
    }

    #[test]
    fn save_rejects_invalid_config_without_writing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("smartmwan");
        std::fs::write(&path, Store::defaults_uci_text()).unwrap();
        let mut store = Store::load(&path).unwrap();
        let before = std::fs::read_to_string(&path).unwrap();
        let mut bad = sample_cfg();
        bad.wans[0].name = "wan;evil".into(); // 非法段名
        let e = store.save(&bad).unwrap_err();
        assert!(matches!(e, Error::Validate(_)), "应报校验错误，实际 {e}");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            before,
            "校验失败不得写盘"
        );
    }

    #[test]
    fn save_creates_backup_on_second_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("smartmwan");
        let mut store = Store::load(&path).unwrap(); // 文件不存在 → 默认配置
        store.save(&sample_cfg()).unwrap();
        assert!(!path.with_extension("bak").exists(), "首次保存没有备份可留");
        let mut c2 = sample_cfg();
        c2.global.algorithm = Algorithm::SrcIp;
        store.save(&c2).unwrap();
        assert!(
            dir.path().join("smartmwan.bak").exists(),
            "第二次保存必须先备份"
        );
    }

    #[test]
    fn applied_snapshot_and_last_good() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let a = Store::store_applied(&state, &sample_cfg(), "tx-1").unwrap();
        assert_eq!(a.transaction, "tx-1");
        assert!(Store::applied_path(&state).exists());
        // 第二次应用后 .last-good 应保留第一次
        let c2 = {
            let mut x = sample_cfg();
            x.global.algorithm = Algorithm::LeastTraffic;
            x
        };
        Store::store_applied(&state, &c2, "tx-2").unwrap();
        let restored = Store::restore_last_good(&state).unwrap().unwrap();
        assert_eq!(
            restored.global.algorithm,
            Algorithm::SrcIpDstIp,
            "last-good 应是第一版"
        );
        let cur = Store::load_applied(&state).unwrap();
        assert_eq!(cur.config.global.algorithm, Algorithm::LeastTraffic);
        assert_eq!(cur.fingerprint, fingerprint(&c2));
    }

    #[test]
    fn fingerprint_changes_only_on_content() {
        let a = fingerprint(&sample_cfg());
        let b = fingerprint(&sample_cfg());
        assert_eq!(a, b, "相同配置指纹必须一致（幂等 apply 依赖它）");
        let mut c = sample_cfg();
        c.wans[0].weight = 9;
        assert_ne!(a, fingerprint(&c));
    }

    #[test]
    fn diff_marks_risky_changes() {
        let old = sample_cfg();
        let mut new = sample_cfg();
        new.global.enabled = false;
        new.global.primary = "wan2".into();
        new.wans[1].weight = 7;
        new.games.remove(0);
        let d = diff(&old, &new);
        assert!(d.iter().any(|c| c.path == "global.enabled" && c.risky));
        assert!(d.iter().any(|c| c.path == "global.primary" && c.risky));
        assert!(d.iter().any(|c| c.path == "wan[wan2].weight" && !c.risky));
        assert!(d
            .iter()
            .any(|c| c.path == "game[mygame]" && c.new == "(删除)"));
        // 无变化时摘要为空
        assert!(diff(&old, &old).is_empty());
    }

    #[test]
    fn migrate_renames_legacy_keys() {
        let raw = "config smartmwan 'global'\n\tlist config_version '1'\n\toption primary_interface 'wan3'\n\toption failback '1'\n\toption mode 'balance'\n";
        let mut file = UciFile::parse(raw).unwrap();
        let mut notes = vec![];
        migrate(&mut file, &mut notes).unwrap();
        let g = file.section(T_GLOBAL, "global").unwrap();
        assert_eq!(g.option("primary").as_deref(), Some("wan3"), "{notes:?}");
        assert_eq!(g.option("failback").as_deref(), Some("auto"));
        assert_eq!(
            g.option("config_version").as_deref(),
            Some(crate::CONFIG_SCHEMA_VERSION.to_string().as_str())
        );
        assert!(!notes.is_empty(), "迁移必须留下说明");
    }

    #[test]
    fn migrate_rejects_future_version() {
        let mut file =
            UciFile::parse("config smartmwan 'global'\n\toption config_version '999'\n").unwrap();
        let e = migrate(&mut file, &mut vec![]).unwrap_err();
        assert!(e.to_string().contains("高于支持"), "{e}");
    }

    #[test]
    fn invalid_enum_value_is_error_not_default() {
        // UI 显示与实际策略不一致是最危险的失败模式之一
        let raw = "config smartmwan 'global'\n\toption mode 'sideways'\n";
        let err = decode(&UciFile::parse(raw).unwrap()).unwrap_err();
        assert!(err.to_string().contains("无法识别"), "{err}");
    }

    #[test]
    fn bad_boolean_falls_back_with_warning() {
        let raw = "config smartmwan 'global'\n\toption enabled 'maybe'\n";
        let cfg = decode(&UciFile::parse(raw).unwrap()).unwrap();
        assert!(!cfg.global.enabled, "非法布尔回落到默认（关闭）");
    }

    #[test]
    fn missing_file_yields_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::load(&dir.path().join("nope")).unwrap();
        assert!(!store.config.global.enabled);
        assert!(store.parse_warnings.is_empty());
    }

    #[test]
    fn decode_sorts_wans_by_priority_then_name() {
        let mut c = sample_cfg();
        c.wans.reverse();
        let file = encode_into(UciFile::default(), &c);
        let back = decode(&file).unwrap();
        assert_eq!(back.wans[0].name, "wan");
        assert_eq!(back.wans[1].name, "wan2");
    }
}
