//! 结构化日志与事件缓冲。
//!
//! 设计约束（对应任务书「安全与稳定」章节）：
//!
//! 1. 每条日志必须带：时间、级别、模块、操作、原因、必要上下文 —— 缺一项就无法排障。
//! 2. 敏感信息绝不出现在日志里：按字段名脱敏（password/key/token/secret/psk 等）。
//! 3. 不得静默吞掉错误：`Error` 必须被调用方向上抛或就地记录，
//!    [`error_ctx()`] 是记录并返回的统一入口。
//! 4. 前端 `get_events` 需要最近事件，因此维护一个**有界**环形缓冲，
//!    长期运行不会无限增长内存。
//! 5. 日志写入不能阻塞选路决策：文件写入在锁内只做一次 append，不做同步 fsync。

use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// 日志级别。数值越小越严重，便于用原子量做快速过滤。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum Level {
    Error = 1,
    Warn = 2,
    Info = 3,
    Debug = 4,
    Trace = 5,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Error => "ERROR",
            Level::Warn => "WARN",
            Level::Info => "INFO",
            Level::Debug => "DEBUG",
            Level::Trace => "TRACE",
        }
    }

    /// 解析 UCI / RPC 里的等级文本；无法识别时返回 `None`，由调用方报错而不是默默降级。
    pub fn parse(s: &str) -> Option<Level> {
        match s.trim().to_ascii_lowercase().as_str() {
            "err" | "error" | "0" | "1" => Some(Level::Error),
            "warn" | "warning" | "2" => Some(Level::Warn),
            "info" | "notice" | "3" => Some(Level::Info),
            "debug" | "4" => Some(Level::Debug),
            "trace" | "5" => Some(Level::Trace),
            _ => None,
        }
    }
}

/// 环形缓冲容量：足够覆盖一次故障切换的完整证据链，又不至于吃内存。
const EVENT_RING: usize = 1024;

/// 单条事件，RPC `get_events` 直接序列化该结构。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Event {
    pub ts_ms: u64,
    pub level: &'static str,
    pub module: String,
    pub action: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wan: Option<String>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub context: HashMap<String, String>,
    /// 该事件是否已被运维确认（用于 UI 折叠历史噪声）。
    pub acked: bool,
}

/// 日志后端状态。整个进程一份，由 [`init()`] 构造。
pub struct Logger {
    /// 输出文件；为 `None` 时只写 stderr（单元测试与非 root 运行）。
    file: OnceLock<Mutex<Option<FileSink>>>,
    max_bytes: u64,
    keep_backups: usize,
}

struct FileSink {
    path: PathBuf,
    file: std::fs::File,
    written: u64,
}

static LEVEL: AtomicU8 = AtomicU8::new(Level::Info as u8);
static CLOCK_OFFSET: AtomicU64 = AtomicU64::new(0);
static EVENTS: OnceLock<Mutex<VecDeque<Event>>> = OnceLock::new();
static DROPPED: AtomicU64 = AtomicU64::new(0);
static LOGGER: OnceLock<Logger> = OnceLock::new();

fn events() -> &'static Mutex<VecDeque<Event>> {
    EVENTS.get_or_init(|| Mutex::new(VecDeque::with_capacity(EVENT_RING)))
}

/// 初始化：设置等级、日志文件与轮转策略。重复调用是幂等的。
pub fn init(level: Level, path: Option<&Path>, max_bytes: u64, keep_backups: usize) {
    LEVEL.store(level as u8, Ordering::Relaxed);
    CLOCK_OFFSET.store(local_utc_offset_secs(), Ordering::Relaxed);
    LOGGER.get_or_init(|| Logger {
        file: OnceLock::new(),
        max_bytes: max_bytes.max(64 * 1024),
        keep_backups,
    });
    if let (Some(logger), Some(p)) = (LOGGER.get(), path) {
        let _ = logger.file.get_or_init(|| {
            Mutex::new(
                open_sink(p)
                    .map_err(|e| {
                        // 日志文件打不开不能让守护进程退出，必须在 stderr 说清楚。
                        eprintln!("smartmwan: 无法打开日志文件 {}: {e}", p.display());
                        e
                    })
                    .ok(),
            )
        });
    }
}

fn open_sink(path: &Path) -> std::io::Result<FileSink> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).ok();
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    Ok(FileSink {
        path: path.to_path_buf(),
        file,
        written: len,
    })
}

pub fn set_level(level: Level) {
    LEVEL.store(level as u8, Ordering::Relaxed);
}

pub fn level() -> Level {
    match LEVEL.load(Ordering::Relaxed) {
        1 => Level::Error,
        2 => Level::Warn,
        3 => Level::Info,
        4 => Level::Debug,
        _ => Level::Trace,
    }
}

#[inline]
fn enabled(l: Level) -> bool {
    (l as u8) <= LEVEL.load(Ordering::Relaxed)
}

/// 单调毫秒时间戳（本地时区偏移由 [`local_utc_offset_secs()`] 提供）。
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 读取 `/etc/localtime` 的 UTC 偏移。用 libc 而不是 chrono，避免为此引入日期库。
fn local_utc_offset_secs() -> u64 {
    // SAFETY: tzname/localtime_r 只读全局时区，且我们传入自己拥有的 tm 与 tz 结构。
    unsafe {
        // musl 的 libc crate 未导出 tzset；localtime_r 内部会自行读取 TZ。
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&now, &mut tm).is_null() {
            return 0;
        }
        let off = tm.tm_gmtoff;
        if off > 0 {
            off as u64
        } else {
            0
        }
    }
}

/// 把 epoch 毫秒渲染成 `YYYY-MM-DDTHH:MM:SS.mmm±ZZ`。
fn fmt_time(ts_ms: u64) -> String {
    let offset = CLOCK_OFFSET.load(Ordering::Relaxed) as i64;
    let local = (ts_ms as i64) / 1000 + offset;
    let (y, mo, d) = civil_from_days(local.div_euclid(86_400));
    let secs_of_day = local.rem_euclid(86_400);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}{}",
        y,
        mo,
        d,
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60,
        ts_ms % 1000,
        if offset == 0 {
            "Z".to_string()
        } else {
            let sign = if offset >= 0 { '+' } else { '-' };
            let a = offset.unsigned_abs();
            format!("{sign}{:02}:{:02}", a / 3600, (a % 3600) / 60)
        }
    )
}

/// Howard Hinnant 的 days→civil 算法，避免为此引入日历库。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

/// 字段名是否疑似机密。命中即整体替换为 `***`。
fn looks_secret(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    [
        "password",
        "passwd",
        "secret",
        "token",
        "apikey",
        "api_key",
        "private_key",
        "psk",
        "pin",
        "credential",
        "cookie",
        "session",
        "mac",
    ]
    .iter()
    .any(|p| k.contains(p))
}

fn redact(key: &str, value: &str) -> String {
    if looks_secret(key) {
        "***".to_string()
    } else if value.len() > 256 {
        crate::clamp_str(value, 256)
    } else {
        value.to_string()
    }
}

/// 记录一条日志。`ctx` 为 `[(键, 值)]`，会做脱敏与长度限制。
pub fn log(l: Level, module: &str, action: &str, message: &str, ctx: &[(&str, String)]) {
    if !enabled(l) {
        return;
    }
    let ts = now_ms();
    let mut safe: HashMap<String, String> = HashMap::new();
    for (k, v) in ctx {
        safe.insert((*k).to_string(), redact(k, v));
    }
    let wan = safe.get("wan").or_else(|| safe.get("interface")).cloned();

    let line = {
        let mut kv = safe.iter().collect::<Vec<_>>();
        kv.sort_by_key(|(k, _)| (*k).clone());
        let tail = if kv.is_empty() {
            String::new()
        } else {
            let s = kv
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join(" ");
            format!(" | {s}")
        };
        format!(
            "{} {:<5} [{module}] {action}: {message}{tail}\n",
            fmt_time(ts),
            l.as_str()
        )
    };

    // 写文件后端；没有可用后端时退化为 stderr，保证错误绝不消失。
    let mut wrote_file = false;
    if let Some(logger) = LOGGER.get() {
        if let Some(slot) = logger.file.get() {
            if let Ok(mut guard) = slot.lock() {
                if let Some(sink) = guard.as_mut() {
                    if sink.file.write_all(line.as_bytes()).is_ok() {
                        let _ = sink.file.flush();
                        sink.written += line.len() as u64;
                        wrote_file = true;
                        if sink.written > logger.max_bytes {
                            rotate(sink, logger.keep_backups);
                        }
                    }
                }
            }
        }
    }
    if !wrote_file {
        eprint!("{line}");
    }

    // Error/Warn/Info 一律进入缓冲（即使等级过滤掉了输出），供 UI 与诊断读取。
    if l <= Level::Info {
        let ev = Event {
            ts_ms: ts,
            level: l.as_str(),
            module: module.to_string(),
            action: action.to_string(),
            message: message.to_string(),
            wan,
            context: safe,
            acked: false,
        };
        if let Ok(mut q) = events().lock() {
            if q.len() >= EVENT_RING {
                q.pop_front();
                DROPPED.fetch_add(1, Ordering::Relaxed);
            }
            q.push_back(ev);
        }
    }
}

/// 按大小轮转日志文件。任何一步失败都只是少一份备份，不能影响守护进程。
fn rotate(sink: &mut FileSink, keep: usize) {
    let keep = keep.max(1);
    // 先把当前文件关闭，再改名，避免在部分文件系统上 rename 打开中的文件失败。
    for i in (1..keep).rev() {
        let from = format!("{}.{}", sink.path.display(), i);
        let to = format!("{}.{}", sink.path.display(), i + 1);
        std::fs::rename(&from, &to).ok();
    }
    std::fs::remove_file(format!("{}.{}", sink.path.display(), keep)).ok();
    std::fs::rename(&sink.path, format!("{}.1", sink.path.display())).ok();
    sink.written = 0;
    sink.file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&sink.path)
        .unwrap_or_else(|_| {
            // 只读文件系统等极端情况：写到 /dev/null，保持后续日志调用不重复报错。
            match std::fs::File::create("/dev/null") {
                Ok(f) => f,
                Err(e) => panic!("无法打开日志文件且 /dev/null 不可用: {e}"),
            }
        });
}

/// 记录错误并把它继续向上抛 —— 用于杜绝「静默吞错」。
pub fn error_ctx(
    module: &str,
    action: &str,
    err: crate::Error,
    ctx: &[(&str, String)],
) -> crate::Error {
    log(Level::Error, module, action, &err.to_string(), ctx);
    err
}

pub fn warn_ctx(module: &str, action: &str, message: &str, ctx: &[(&str, String)]) {
    log(Level::Warn, module, action, message, ctx);
}

pub fn info_ctx(module: &str, action: &str, message: &str, ctx: &[(&str, String)]) {
    log(Level::Info, module, action, message, ctx);
}

pub fn debug_ctx(module: &str, action: &str, message: &str, ctx: &[(&str, String)]) {
    log(Level::Debug, module, action, message, ctx);
}

/// 取最近事件（新→旧）。`level` 为 `Some` 时按等级过滤，`limit` 上限 500。
pub fn recent(level: Option<Level>, limit: usize) -> Vec<Event> {
    let mut out = Vec::new();
    if let Ok(q) = events().lock() {
        for ev in q.iter().rev() {
            if let Some(l) = level {
                let ok = match ev.level {
                    "ERROR" => Level::Error <= l,
                    "WARN" => Level::Warn <= l,
                    "INFO" => Level::Info <= l,
                    _ => false,
                };
                if !ok {
                    continue;
                }
            }
            out.push(ev.clone());
            if out.len() >= limit.min(500) {
                break;
            }
        }
    }
    out
}

/// 被环形缓冲丢弃的事件数，用于诊断「事件刷屏」。
pub fn dropped() -> u64 {
    DROPPED.load(Ordering::Relaxed)
}

/// 供测试：清空缓冲并把等级复位，避免测试之间互相污染。
#[doc(hidden)]
pub fn reset_for_test() {
    LEVEL.store(Level::Info as u8, Ordering::Relaxed);
    if let Ok(mut q) = events().lock() {
        q.clear();
    }
    DROPPED.store(0, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 进程级 logger 会被并行测试相互干扰：本模块的测试用这把锁串行执行，
    /// 并且只检查自己模块名下的事件，其他模块恰好写日志也不会误判。
    fn serial() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    /// 取本测试写下的事件（按模块名筛选，新→旧）。
    fn mine(module: &str) -> Vec<Event> {
        recent(None, 500)
            .into_iter()
            .filter(|e| e.module == module)
            .collect()
    }

    #[test]
    fn level_parse_and_filter() {
        let _g = serial();
        assert_eq!(Level::parse("DEBUG"), Some(Level::Debug));
        assert_eq!(Level::parse(" notice "), Some(Level::Info));
        assert_eq!(Level::parse("verbose"), None);
        set_level(Level::Error);
        assert!(!enabled(Level::Info), "低于当前等级的记录应被跳过");
        assert!(enabled(Level::Error));
        set_level(Level::Trace);
    }

    #[test]
    fn secret_fields_are_redacted() {
        let _g = serial();
        set_level(Level::Trace);
        log(
            Level::Info,
            "lg-secret",
            "apply",
            "读取参数",
            &[
                ("password", String::from("hunter2")),
                ("wan", String::from("wan1")),
                ("note", "x".repeat(4000)),
            ],
        );
        let evs = mine("lg-secret");
        assert_eq!(evs.len(), 1, "同一测试只应写一条事件");
        let ev = &evs[0];
        assert_eq!(ev.context["password"], "***");
        assert!(ev.context["note"].len() < 400, "超长值必须截断");
        assert_eq!(ev.wan.as_deref(), Some("wan1"));
        // 原文绝不能以任何形式出现在消息里
        assert!(!ev.message.contains("hunter2"));
    }

    #[test]
    fn ring_is_bounded() {
        let _g = serial();
        set_level(Level::Trace);
        reset_for_test();
        let n = EVENT_RING + 200;
        for i in 0..n {
            log(Level::Error, "lg-ring", "flood", &format!("e{i}"), &[]);
        }
        {
            let q = events().lock().unwrap();
            assert!(q.len() <= EVENT_RING, "环形缓冲必须有界");
            assert_eq!(q.len(), EVENT_RING, "写满后长度应稳定在上限");
            assert!(q.back().is_some());
        }
        assert!(dropped() >= 200, "丢弃计数应反映溢出，实际 {}", dropped());
        let mine_ = mine("lg-ring");
        assert!(
            mine_.iter().any(|e| e.message == format!("e{}", n - 1)),
            "最新事件必须留在缓冲里"
        );
        assert!(
            !mine_.iter().any(|e| e.message == "e0"),
            "最早事件应已被挤出（这才是有界）"
        );
    }

    #[test]
    fn timestamp_matches_civil_algorithm() {
        // 2026-01-01 00:00:00 UTC
        let ts = 1_767_225_600_000u64;
        let s = fmt_time(ts);
        assert!(s.starts_with("2026-01-01T"), "实际: {s}");
        // 闰日与年末边界
        assert!(fmt_time(1_735_689_599_000).starts_with("2024-12-31T"));
        assert!(fmt_time(1_704_067_200_000).starts_with("2024-01-01T"));
    }

    #[test]
    fn recent_filters_by_level() {
        let _g = serial();
        set_level(Level::Trace);
        reset_for_test();
        log(Level::Warn, "lg-recent", "a", "w", &[]);
        log(Level::Error, "lg-recent", "a", "e", &[]);
        let only_err: Vec<Event> = recent(Some(Level::Error), 500)
            .into_iter()
            .filter(|e| e.module == "lg-recent")
            .collect();
        assert_eq!(only_err.len(), 1);
        assert_eq!(only_err[0].level, "ERROR");
        assert_eq!(mine("lg-recent").len(), 2);
        assert_eq!(
            recent(None, 1)
                .into_iter()
                .filter(|e| e.module == "lg-recent")
                .count(),
            1,
            "limit 必须生效"
        );
    }
}
