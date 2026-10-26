//! smartmwan —— OpenWrt 25.12 / ImmortalWrt 多 WAN 智能选路守护进程。
//!
//! 分层（另见 docs/architecture.md）：
//!
//! ```text
//! main.rs ──装配──► scheduler ──决策──► transaction ──安全提交──► system::{route,firewall}
//!                    ▲              ▲             ▲
//!                    │              │             └── rules（流量分类：游戏/客户端/端口）
//!                    │              └── health（探测 + 指标 + 线路状态机）
//!                    └── config（UCI 模型 + 校验 + 迁移）        rpc（LuCI 面向的接口）
//! ```
//!
//! 全项目不使用 Lua：后端为 Rust，前端为 LuCI 原生 JavaScript，RPC 桥接为 rpcd 的
//! ucode 插件。OpenWrt 25.12 的 LuCI 框架自身也已完全迁移到 ucode（`luci-base` 中已无
//! `luasrc/`，依赖列表无任何 Lua 包）。

pub mod config;
pub mod health;
pub mod logging;
pub mod rpc;
pub mod rules;
pub mod scheduler;
pub mod system;
pub mod transaction;

/// `/etc/config/smartmwan` 的模式版本。布局发生不兼容变更时递增，
/// 由 `config::migrate()` 就地升级，保证老配置不会被静默误读。
pub const CONFIG_SCHEMA_VERSION: u32 = 4;

/// RPC 协议版本。视图启动时握手，版本不符直接拒绝渲染，而不是猜字段含义。
pub const RPC_PROTOCOL: u32 = 1;

/// 本守护进程在内核中拥有的所有对象（nft 表/链/集合/计数器、路由表名）的前缀。
/// 清理与所有权判定一律基于该前缀，**绝不**使用整表 flush。
pub const NS: &str = "smw";

/// 项目统一错误类型。RPC 层把它映射成稳定的错误码，日志层把它展开成上下文。
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("配置错误: {0}")]
    Config(String),

    #[error("校验失败: {0}")]
    Validate(String),

    #[error("netlink 错误: {0}")]
    Netlink(String),

    #[error("nftables 错误: {0}")]
    Firewall(String),

    #[error("外部命令 {cmd} 失败: {reason}")]
    Exec { cmd: String, reason: String },

    #[error("事务已回滚: {0}")]
    Rollback(String),

    #[error("权限不足: {0}")]
    Permission(String),

    #[error("不支持: {0}")]
    Unsupported(String),

    #[error("超时: {operation}（{elapsed_ms}ms）")]
    Timeout { operation: String, elapsed_ms: u64 },

    #[error("线路 {wan} 不可用: {reason}")]
    NoRoute { wan: String, reason: String },

    #[error(transparent)]
    Io(#[from] std::io::Error),

    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

/// 便于所有模块统一返回 `Result`。
pub type Result<T, E = Error> = std::result::Result<T, E>;

impl Error {
    /// 稳定的机器可读错误码，前端据此区分「可重试」与「需用户修正」。
    pub fn code(&self) -> &'static str {
        match self {
            Error::Config(_) => "config",
            Error::Validate(_) => "validate",
            Error::Netlink(_) => "netlink",
            Error::Firewall(_) => "firewall",
            Error::Exec { .. } => "exec",
            Error::Rollback(_) => "rollback",
            Error::Permission(_) => "permission",
            Error::Unsupported(_) => "unsupported",
            Error::Timeout { .. } => "timeout",
            Error::NoRoute { .. } => "no_route",
            Error::Io(_) => "io",
            Error::Json(_) => "json",
        }
    }
}

/// fwmark 布局 —— 全项目最重要的约定，改这里等于改数据平面语义。
///
/// ```text
/// bit  31        28 27        24 23        16 15   12 11        8 7            0
///      ┌───────────┬────────────┬────────────┬─────────┬──────────┬────────────┐
///      │ 保留(=0)  │ 魔数 0x5   │ bucket[7:0]│ gen[3:0] │class[3:0]│  WAN 槽位  │
///      └───────────┴────────────┴────────────┴─────────┴──────────┴────────────┘
///      0xF0000000   0x0F000000   0x00FF0000   0x0000F000 0x00000F00 0x000000FF
/// ```
///
/// * 槽位 `slot` 取值 1..=MAX_WANS，0 表示「未标记」，永不安装到内核规则里；
/// * 槽位对应的路由表号 = `TABLE_BASE + slot`，因此始终 < 253，避免与
///   `main`(254)/`local`(255)/`universe`(253) 冲突；
/// * `ip rule` 一律使用 `RULE_MASK`（仅低 8 位），所以 bucket/gen/class 的
///   变化不会影响选表，规则总数恒等于启用线路数 —— 这是「不做高频全量重建」的前提。
/// * **魔数存在的原因**：连接标记（ct mark）是全局共享资源，fw4 的策略路由、SQM、
///   其它插件都会写它。本插件继承 ct mark 之前必须先判断「这个标记是不是我的」，
///   而 `ct mark != 0` 这种判断会把别人的标记也吞掉。有了 bit24..27 = 0x5 的约束，
///   所有权判断可以写成一条 nft 区间匹配 `ct mark 0x05000000-0x05ffffff`
///   —— 区间恰好等价于「魔数正确且 bit28..31 为 0」，不需要 nft 位运算表达式
///   （位运算在 ct mark 上的语法兼容性更弱，避免依赖）。
/// * 落在别人的标记区间时本插件**完全不介入**该连接（见 firewall.rs 的共存规则），
///   宁可让这条连接走 main 表，也不去抢别人的出口决策。
pub mod marks {
    use std::fmt;

    pub const SLOT_MASK: u32 = 0x0000_00FF;
    pub const CLASS_SHIFT: u32 = 8;
    pub const CLASS_MASK: u32 = 0x0000_0F00;
    pub const GEN_SHIFT: u32 = 12;
    pub const GEN_MASK: u32 = 0x0000_F000;
    pub const BUCKET_SHIFT: u32 = 16;
    pub const BUCKET_MASK: u32 = 0x00FF_0000;
    pub const MAGIC_SHIFT: u32 = 24;
    pub const MAGIC_MASK: u32 = 0x0F00_0000;
    /// 本插件专属魔数。
    pub const MAGIC: u32 = 0x5;

    /// 安装进内核的每条 `ip rule` 使用的掩码：只有槽位参与选表。
    pub const RULE_MASK: u32 = SLOT_MASK;

    pub const MAX_WANS: u8 = 24;
    pub const TABLE_BASE: u32 = 100;
    /// 哈希/负载分桶数量。桶数决定了重新映射的粒度上限。
    pub const BUCKETS: u16 = 64;

    /// 流量类别，仅用于规则归属与可观测性，不参与选表。
    pub const CLASS_NORMAL: u32 = 0;
    pub const CLASS_GAME: u32 = 1;
    pub const CLASS_MANUAL: u32 = 2;
    pub const CLASS_LOCAL_POLICY: u32 = 3;

    /// bit28..31 必须为 0，留给 fw4/netifd/其它包。
    pub const RESERVED_HIGH: u32 = 0xF000_0000;

    /// 所有权区间（含端点）：所有本插件产生的标记都落在这里。
    pub const OWN_MIN: u32 = MAGIC << MAGIC_SHIFT;
    pub const OWN_MAX: u32 =
        (MAGIC << MAGIC_SHIFT) | BUCKET_MASK | GEN_MASK | CLASS_MASK | SLOT_MASK;

    /// nft 规则里使用的区间文本。
    pub const fn own_range_text() -> &'static str {
        "0x05000000-0x05ffffff"
    }

    /// 组装一个标记；槽位/类别越界直接 panic —— 这是编程错误，不是运行时输入。
    pub fn mark(slot: u8, class: u32, gen: u8, bucket: u16) -> u32 {
        assert!((1..=MAX_WANS).contains(&slot), "WAN 槽位越界: {slot}");
        assert!(class <= 15, "类别越界: {class}");
        let m = ((MAGIC & 0x0F) << MAGIC_SHIFT)
            | ((slot as u32) & 0xFF)
            | ((class & 0x0F) << CLASS_SHIFT)
            | (((gen as u32) & 0x0F) << GEN_SHIFT)
            | (((bucket as u32) & 0xFF) << BUCKET_SHIFT);
        debug_assert_eq!(m & RESERVED_HIGH, 0, "标记落入保留带");
        debug_assert!(is_own(m), "标记必须带魔数");
        m
    }

    /// 判断一个（可能来自他人的）标记是否属于本插件。
    pub fn is_own(m: u32) -> bool {
        (OWN_MIN..=OWN_MAX).contains(&m)
    }

    pub fn slot_of(m: u32) -> u8 {
        (m & SLOT_MASK) as u8
    }

    pub fn class_of(m: u32) -> u32 {
        (m & CLASS_MASK) >> CLASS_SHIFT
    }

    pub fn gen_of(m: u32) -> u8 {
        ((m & GEN_MASK) >> GEN_SHIFT) as u8
    }

    pub fn bucket_of(m: u32) -> u16 {
        ((m & BUCKET_MASK) >> BUCKET_SHIFT) as u16
    }

    pub fn table_of(slot: u8) -> u32 {
        TABLE_BASE + slot as u32
    }

    /// 十六进制标记文本，nftables/`ip rule` 一律用它，避免十进制/十六进制混淆。
    pub fn hex(m: u32) -> MarkHex {
        MarkHex(m)
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct MarkHex(u32);

    impl fmt::Display for MarkHex {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "0x{:08x}", self.0)
        }
    }
}

/// 解析用户书写的标记：接受十进制或 `0x` 十六进制（用户常从 `ip rule` 输出粘贴）。
pub fn parse_mark(s: &str) -> Option<u32> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        Some(hex) => u32::from_str_radix(hex, 16).ok(),
        None => s.parse::<u32>().ok(),
    }
}

/// 有限长字符串截断：日志与 RPC 输出必须防止无界字符串（外部命令回显、异常路径）。
pub fn clamp_str(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    // 按字符边界截断，避免切在多字节 UTF-8 中间导致 panic。
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…[截断 {}→{} 字节]", &s[..end], s.len(), end)
}

#[cfg(test)]
mod core_tests {
    use super::*;

    /// 注意：Rust 不接受非 ASCII 标识符，测试函数名用英文，说明一律用中文注释。

    #[test]
    fn mark_fields_roundtrip() {
        let m = marks::mark(3, marks::CLASS_GAME, 5, 41);
        assert_eq!(marks::slot_of(m), 3);
        assert_eq!(marks::class_of(m), marks::CLASS_GAME);
        assert_eq!(marks::bucket_of(m), 41);
        assert_eq!(marks::gen_of(m), 5);
        assert_eq!(marks::table_of(3), 103);
        assert_eq!(m & marks::RULE_MASK, 3, "规则掩码必须只隔离槽位");
        assert_eq!(m & marks::RESERVED_HIGH, 0);
        assert_eq!(m & marks::MAGIC_MASK, marks::MAGIC << marks::MAGIC_SHIFT);
    }

    #[test]
    fn ownership_covers_every_legal_mark() {
        // 全部合法组合都必须落在所有权区间内 —— nft 的区间匹配依赖这个不变式。
        for slot in 1..=marks::MAX_WANS {
            for class in [
                marks::CLASS_NORMAL,
                marks::CLASS_GAME,
                marks::CLASS_MANUAL,
                marks::CLASS_LOCAL_POLICY,
            ] {
                for gen in 0..16u8 {
                    for bucket in 0..marks::BUCKETS {
                        let m = marks::mark(slot, class, gen, bucket);
                        assert!(marks::is_own(m), "0x{m:08x} 应属于本插件");
                        assert!((marks::OWN_MIN..=marks::OWN_MAX).contains(&m));
                    }
                }
            }
        }
        // 区间文本必须与常量一致（写错会直接导致所有权判断失效）。
        assert_eq!(
            marks::own_range_text(),
            format!("0x{:08x}-0x{:08x}", marks::OWN_MIN, marks::OWN_MAX)
        );
        // 他人的典型 connmark（fw4 策略路由常用小数值）绝不能被判为我们的。
        for foreign in [
            0u32,
            1,
            2,
            0x3e,
            0x64,
            0x100,
            0x8000_0000,
            0xf000_0001,
            0x0600_0001,
        ] {
            assert!(!marks::is_own(foreign), "0x{foreign:08x} 不属于本插件");
        }
    }

    #[test]
    fn bucket_and_gen_changes_do_not_affect_table() {
        // 核心不变式：改变桶或代际绝不能改变选中的路由表，否则已建立连接会换出口。
        for bucket in 0..marks::BUCKETS {
            for gen in 0..16u8 {
                let a = marks::mark(1, marks::CLASS_NORMAL, 0, 0);
                let b = marks::mark(1, marks::CLASS_NORMAL, gen, bucket);
                assert_eq!(a & marks::RULE_MASK, b & marks::RULE_MASK);
            }
        }
    }

    #[test]
    fn mark_text_parsing() {
        assert_eq!(parse_mark("0x103"), Some(0x103));
        assert_eq!(parse_mark("259"), Some(259));
        assert_eq!(parse_mark(" no "), None);
        assert_eq!(marks::hex(0x103).to_string(), "0x00000103");
    }

    #[test]
    fn clamp_keeps_utf8_boundary() {
        let s = "中文字符串测试".repeat(20);
        let c = clamp_str(&s, 10);
        assert!(c.len() < s.len());
        assert!(c.contains("截断"));
        // 任意截断长度都不得 panic
        for n in 0..40 {
            let _ = clamp_str(&s, n);
        }
    }

    #[test]
    #[should_panic(expected = "越界")]
    fn slot_zero_is_rejected() {
        let _ = marks::mark(0, marks::CLASS_NORMAL, 0, 0);
    }
}
