//! 外部命令执行器。
//!
//! 任务书第二节第 5 条要求「禁止字符串拼接 shell」，本模块是唯一的对外执行入口，规则如下：
//!
//! * 程序名必须在 [`ALLOWED_PROGRAMS`] 白名单内，且必须是绝对路径 —— 不接受 `$PATH` 查找，
//!   避免被 `PATH` 注入；
//! * 参数以数组传给 `execve`，**永不**经过 `sh -c`，因此不存在引号/分号注入面；
//! * 每次调用都有硬超时，超时后 kill 子进程并回收，返回 [`Error::Timeout`]；
//! * stdout/stderr 读取有字节上限，超限后继续排空管道（否则子进程会卡在写管道上）但丢弃内容，
//!   并置 `truncated` 标记，日志里只出现截断后的内容；
//! * stdin 恒为 `/dev/null`，环境变量清空后只保留最小 `PATH`，避免把 `TERM`/`LD_*` 等
//!   脏环境传给子进程；
//! * 非零退出码一律是错误，不会被静默忽略。
//!
//! 注：优先使用 netlink / `/sys` / `/proc` 等系统接口（见同目录其它模块），只有
//! `nft` 这类没有稳定库接口（或需要原子事务）的命令才走这里。

use std::collections::HashSet;
use std::path::Path;
use std::process::Stdio;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;

use crate::logging;
use crate::{clamp_str, Error, Result};

/// 允许执行的程序绝对路径白名单。
///
/// 这里列的是 OpenWrt 25.12 上的实际安装位置候选；运行期由 [`resolve_program`] 选出
/// 设备上真实存在的那个（`nft` 在 `/usr/sbin`，`ip` 在 `/sbin`）。
const ALLOWED_PROGRAMS: &[&str] = &[
    "/usr/sbin/nft",
    "/sbin/nft",
    "/sbin/ip",
    "/usr/sbin/ip",
    "/sbin/tc",
    "/usr/sbin/tc",
    "/usr/bin/ubus",
    "/sbin/ubus",
    "/sbin/service",
    "/usr/bin/logger",
];

/// 只有单元测试构建才会加入的额外程序；release 构建里这段常量不存在，
/// 因此不可能通过测试通道放宽生产环境白名单。
#[cfg(test)]
const TEST_PROGRAMS: &[&str] = &[
    "/bin/sleep",
    "/usr/bin/sleep",
    "/bin/cat",
    "/usr/bin/cat",
    "/bin/echo",
    "/usr/bin/echo",
    "/bin/false",
    "/usr/bin/false",
    "/bin/true",
    "/usr/bin/true",
    "/bin/dd",
    "/usr/bin/dd",
    // 仅测试用：在白名单内、但设备上必然不存在的绝对路径，用来验证 spawn 失败
    // 走 Error::Exec 而不是 panic。
    "/bin/smw-definitely-missing",
];

/// 解析程序路径：按候选顺序返回设备上存在的第一个绝对路径。
///
/// `None` 表示本插件依赖的命令缺失 —— 调用方必须把它变成明确的错误/降级，
/// 而不是回退到别的路径或猜测。
pub fn resolve_program(candidates: &[&str]) -> Option<String> {
    let allowed = allowed_set();
    for c in candidates {
        if !allowed.contains(*c) {
            // 白名单外的候选直接忽略：即使设备上存在也不执行。
            continue;
        }
        if Path::new(c).is_file() {
            return Some((*c).to_string());
        }
    }
    None
}

fn allowed_set() -> &'static HashSet<&'static str> {
    static SET: OnceLock<HashSet<&'static str>> = OnceLock::new();
    SET.get_or_init(|| {
        // 测试构建会追加假程序名，因此需要可变；正式构建一次性构造即可。
        #[allow(unused_mut)]
        let mut s: HashSet<&'static str> = ALLOWED_PROGRAMS.iter().copied().collect();
        #[cfg(test)]
        for p in TEST_PROGRAMS {
            s.insert(p);
        }
        s
    })
}

/// 一次调用的完整描述。构造即校验，避免「先拼接后检查」。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invocation {
    pub program: String,
    pub args: Vec<String>,
    pub timeout: Duration,
    pub max_output: usize,
    /// 日志/错误里显示的名字（不含参数，参数可能带隐私）。
    pub label: String,
}

/// 默认输出上限：4 KiB 足够 `nft -c` 的报错，又能挡住异常刷屏。
pub const DEFAULT_MAX_OUTPUT: usize = 4096;
/// 默认超时：`nft` 装载一个几百行的表在普通设备上远小于此值。
pub const DEFAULT_TIMEOUT_MS: u64 = 5000;

impl Invocation {
    /// 构造一次调用。程序必须是绝对路径且在白名单内，参数不得含换行与 NUL。
    ///
    /// 参数里出现换行通常是配置被污染或校验漏了的信号，这里直接拒绝：
    /// 内核 netlink/nft 的 ifname、set 名等标识符本身就不允许换行。
    pub fn new(program: &str, args: &[&str], label: &str) -> Result<Invocation> {
        Invocation::with_options(
            program,
            args,
            Duration::from_millis(DEFAULT_TIMEOUT_MS),
            DEFAULT_MAX_OUTPUT,
            label,
        )
    }

    pub fn with_options(
        program: &str,
        args: &[&str],
        timeout: Duration,
        max_output: usize,
        label: &str,
    ) -> Result<Invocation> {
        if program.is_empty() || !program.starts_with('/') {
            return Err(Error::Permission(format!(
                "拒绝执行非绝对路径命令: {program}"
            )));
        }
        if !allowed_set().contains(program) {
            return Err(Error::Permission(format!("命令不在白名单内: {program}")));
        }
        if timeout.is_zero() {
            return Err(Error::Config("命令超时不得为 0".into()));
        }
        let mut checked = Vec::with_capacity(args.len());
        for a in args {
            if a.contains('\0') || a.contains('\n') {
                return Err(Error::Validate(format!(
                    "命令参数含非法字符（换行或 NUL）: {}",
                    clamp_str(a, 64)
                )));
            }
            checked.push((*a).to_string());
        }
        Ok(Invocation {
            program: program.to_string(),
            args: checked,
            timeout,
            max_output: max_output.max(1),
            label: if label.is_empty() {
                program.to_string()
            } else {
                label.to_string()
            },
        })
    }

    /// 用于 `nft -f` / `nft -c -f`：把生成好的脚本文件（0600，位于 state_dir）交给 nft。
    ///
    /// `-c`（只试算不提交）必须与 `-f <文件>` **同时**出现：`nft -c <路径>` 会把
    /// 路径当成一条命令来解析，报 `syntax error, unexpected /` 然后失败。
    /// 这条曾让真机上每一笔事务都死在试算阶段（沙箱的替身不执行真命令，所以没暴露），
    /// 回归测试锁死「check 调用的参数里 -c 与 -f 成对出现」。
    pub fn nft_file(
        nft: &str,
        file: &Path,
        check_only: bool,
        timeout: Duration,
    ) -> Result<Invocation> {
        let path = file
            .to_str()
            .ok_or_else(|| Error::Config("nft 脚本路径不是合法 UTF-8".into()))?;
        let args: Vec<&str> = if check_only {
            vec!["-c", "-f", path]
        } else {
            vec!["-f", path]
        };
        Invocation::with_options(nft, &args, timeout, 8192, "nft")
    }
}

/// 一次调用的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub label: String,
    /// 退出码；被超时 kill 时不会出现在这里（那种情况直接返回 Err）。
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
    pub elapsed_ms: u64,
}

impl Outcome {
    pub fn ok(&self) -> bool {
        self.status == 0
    }

    /// 供日志使用的一行摘要，保证长度有限。
    pub fn summary(&self) -> String {
        format!(
            "{} 退出码={} 耗时={}ms stdout={}{} stderr={}{}",
            self.label,
            self.status,
            self.elapsed_ms,
            self.stdout.len(),
            if self.stdout_truncated {
                "(截断)"
            } else {
                ""
            },
            self.stderr.len(),
            if self.stderr_truncated {
                "(截断)"
            } else {
                ""
            },
        )
    }
}

/// 执行命令，不做退出码判断（有些命令的非零退出是合法的探测结果，例如 `ping -c1`）。
pub async fn run(inv: &Invocation) -> Result<Outcome> {
    let started = Instant::now();
    let mut child = match build_command(inv).spawn() {
        Ok(c) => c,
        Err(e) => {
            // 命令不存在/权限不足：明确报错并写日志，绝不回退到 shell。
            let msg = format!("启动 {} 失败: {e}", inv.program);
            return Err(logging::error_ctx(
                "exec",
                "spawn",
                Error::Exec {
                    cmd: inv.label.clone(),
                    reason: msg,
                },
                &[("program", inv.program.clone())],
            ));
        }
    };
    let stdout_pipe = child.stdout.take();
    let stderr_pipe = child.stderr.take();
    let cap = inv.max_output;

    let collect = async move {
        // 两个管道并发读取：只读一个的话另一个写满后会死锁。
        tokio::join!(
            read_bounded_opt(stdout_pipe, cap),
            read_bounded_opt(stderr_pipe, cap)
        )
    };

    let ((stdout, stdout_truncated), (stderr, stderr_truncated)) =
        match tokio::time::timeout(inv.timeout, collect).await {
            Ok(v) => v,
            Err(_) => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                let elapsed = started.elapsed().as_millis() as u64;
                return Err(Error::Timeout {
                    operation: format!("exec:{}", inv.label),
                    elapsed_ms: elapsed,
                });
            }
        };

    let status = match tokio::time::timeout(Duration::from_secs(5), child.wait()).await {
        Ok(Ok(st)) => st.code().unwrap_or(-1),
        Ok(Err(e)) => {
            return Err(Error::Exec {
                cmd: inv.label.clone(),
                reason: format!("等待子进程失败: {e}"),
            });
        }
        Err(_) => {
            let _ = child.kill().await;
            return Err(Error::Timeout {
                operation: format!("exec:{}(wait)", inv.label),
                elapsed_ms: started.elapsed().as_millis() as u64,
            });
        }
    };

    Ok(Outcome {
        label: inv.label.clone(),
        status,
        stdout,
        stderr,
        stdout_truncated,
        stderr_truncated,
        elapsed_ms: started.elapsed().as_millis() as u64,
    })
}

/// 执行并要求退出码为 0；非零时把 stderr 摘要放进错误信息。
pub async fn run_ok(inv: &Invocation) -> Result<Outcome> {
    let out = run(inv).await?;
    if !out.ok() {
        let reason = if !out.stderr.trim().is_empty() {
            clamp_str(out.stderr.trim(), 512)
        } else if !out.stdout.trim().is_empty() {
            clamp_str(out.stdout.trim(), 512)
        } else {
            format!("退出码 {}", out.status)
        };
        logging::warn_ctx(
            "exec",
            "nonzero",
            &out.summary(),
            &[("label", out.label.clone())],
        );
        return Err(Error::Exec {
            cmd: inv.label.clone(),
            reason,
        });
    }
    Ok(out)
}

fn build_command(inv: &Invocation) -> Command {
    let mut c = Command::new(&inv.program);
    c.args(&inv.args);
    c.stdin(Stdio::null());
    c.stdout(Stdio::piped());
    c.stderr(Stdio::piped());
    // 清空环境，只给最小 PATH：不把 HOME/TMPDIR/LD_PRELOAD 等传给子进程。
    c.env_clear();
    c.env("PATH", "/usr/sbin:/sbin:/usr/bin:/bin");
    // 超时后 future 被 drop，kill_on_drop 保证子进程不会变成孤儿继续跑。
    c.kill_on_drop(true);
    c
}

async fn read_bounded_opt<R>(pipe: Option<R>, cap: usize) -> (String, bool)
where
    R: AsyncRead + Unpin,
{
    match pipe {
        None => (String::new(), false),
        Some(r) => read_bounded(r, cap).await,
    }
}

/// 读取至多 `cap` 字节，随后继续排空到 EOF。
///
/// 排空是必要的：若直接停止读取，子进程写满管道缓冲区后会永久阻塞，
/// 于是我们只能靠超时杀进程，那样会掩盖真正的错误信息。
async fn read_bounded<R>(mut r: R, cap: usize) -> (String, bool)
where
    R: AsyncRead + Unpin,
{
    let mut kept: Vec<u8> = Vec::new();
    let mut drained: u64 = 0;
    let mut truncated = false;
    let mut buf = [0u8; 4096];
    loop {
        match r.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => {
                if kept.len() + n <= cap {
                    kept.extend_from_slice(&buf[..n]);
                } else {
                    let room = cap.saturating_sub(kept.len());
                    kept.extend_from_slice(&buf[..room]);
                    truncated = true;
                }
                if truncated {
                    drained += n as u64;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                truncated = true;
                break;
            }
        }
    }
    if truncated {
        // 丢弃内容但仍要把管道读完，避免子进程阻塞。
        loop {
            match r.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => drained += n as u64,
            }
        }
        logging::warn_ctx(
            "exec",
            "output-cap",
            &format!("子进程输出超出上限，已丢弃 {drained} 字节（上限 {cap}）"),
            &[],
        );
    }
    // 子进程输出不保证是 UTF-8：lossy 转换，避免 unwrap panic。
    (String::from_utf8_lossy(&kept).into_owned(), truncated)
}

/// 探测设备上可用的 `nft`，供能力检测使用。
pub fn nft_program() -> Option<String> {
    resolve_program(&["/usr/sbin/nft", "/sbin/nft"])
}

/// 探测 `ip`（ip-full / iproute2）。busybox 版 `ip` 不支持 `ip rule` 的 fwmark 掩码，
/// 因此这里只接受 iproute2 的安装路径，并在调用方检查 `ip -V` 输出。
pub fn ip_program() -> Option<String> {
    resolve_program(&["/sbin/ip", "/usr/sbin/ip"])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sleep_program() -> String {
        resolve_program(&["/bin/sleep", "/usr/bin/sleep"]).expect("测试环境需要 sleep")
    }

    fn cat_program() -> String {
        resolve_program(&["/bin/cat", "/usr/bin/cat"]).expect("测试环境需要 cat")
    }

    fn echo_program() -> String {
        resolve_program(&["/bin/echo", "/usr/bin/echo"]).expect("测试环境需要 echo")
    }

    /// nft 探测路径的白名单程序（测试替身：`/bin/true` 恒成功）。
    fn nft_stub() -> String {
        resolve_program(&["/bin/true", "/usr/bin/true"]).expect("测试环境需要 true")
    }

    #[test]
    fn nft_check_invocation_pairs_c_with_f() {
        // `nft -c <文件>` 会把文件路径当成命令解析（真机实测报
        // `syntax error, unexpected /`），试算因此永远失败、每笔事务都死在
        // 第一阶段。这里锁死 check 调用的参数形态：-c 与 -f 必须成对。
        let p = nft_stub();
        let f = std::path::Path::new("/state/smw-1-1.nft");
        let check = Invocation::nft_file(&p, f, true, Duration::from_millis(1000)).unwrap();
        assert_eq!(check.args, vec!["-c", "-f", "/state/smw-1-1.nft"]);
        let apply = Invocation::nft_file(&p, f, false, Duration::from_millis(1000)).unwrap();
        assert_eq!(apply.args, vec!["-f", "/state/smw-1-1.nft"]);
    }

    #[test]
    fn rejects_shell_metacharacters_and_relative_paths() {
        // 相对路径、非白名单程序一律拒绝。
        assert!(matches!(
            Invocation::new("sh", &["-c", "rm -rf /"], "x"),
            Err(Error::Permission(_))
        ));
        assert!(matches!(
            Invocation::new("/bin/sh", &["-c", "id"], "x"),
            Err(Error::Permission(_))
        ));
        // 参数里的换行/NUL 被拒绝。
        let p = echo_program();
        assert!(matches!(
            Invocation::new(&p, &["a\nb"], "x"),
            Err(Error::Validate(_))
        ));
        assert!(matches!(
            Invocation::new(&p, &["a\0b"], "x"),
            Err(Error::Validate(_))
        ));
    }

    #[test]
    fn whitelist_contains_only_expected_programs() {
        assert!(!ALLOWED_PROGRAMS.contains(&"/bin/sh"));
        assert!(!ALLOWED_PROGRAMS.contains(&"/bin/bash"));
        assert!(ALLOWED_PROGRAMS.contains(&"/usr/sbin/nft"));
        // 生产白名单里绝不能有测试专用程序。
        assert!(!ALLOWED_PROGRAMS.contains(&"/bin/sleep"));
    }

    #[test]
    fn resolve_skips_non_whitelisted_paths() {
        // /bin/sh 在测试沙箱里确实存在，但不在白名单，必须解析失败。
        assert!(resolve_program(&["/bin/sh"]).is_none());
        assert!(resolve_program(&["/definitely/not/here"]).is_none());
    }

    #[test]
    fn bounded_output_truncates_at_cap() {
        // 从 read_bounded 的纯函数层面验证：保留 cap 字节、置截断标记、不 panic。
        let big = vec![b'a'; 300_000];
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let (s, tr) = rt.block_on(read_bounded(&big[..], 1024));
        assert_eq!(s.len(), 1024);
        assert!(tr);
        let (s2, tr2) = rt.block_on(read_bounded(&big[..], 400_000));
        assert_eq!(s2.len(), 300_000);
        assert!(!tr2);
    }

    #[test]
    fn lossy_conversion_never_panics_on_invalid_utf8() {
        let raw: Vec<u8> = vec![0xe4, 0x00, 0x41]; // 非法 UTF-8 序列
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let (s, _) = rt.block_on(read_bounded(&raw[..], 16));
        assert!(s.contains('A'));
    }

    #[tokio::test]
    async fn runs_and_captures_stdout() {
        let p = echo_program();
        let inv = Invocation::new(&p, &["hello", "world"], "echo-test").unwrap();
        let out = run(&inv).await.unwrap();
        assert_eq!(out.status, 0);
        assert_eq!(out.stdout.trim(), "hello world");
        assert!(out.ok());
        assert!(out.summary().contains("退出码=0"));
    }

    #[tokio::test]
    async fn non_zero_exit_is_an_error() {
        let p = resolve_program(&["/bin/false", "/usr/bin/false"]).expect("测试环境需要 false");
        let inv = Invocation::new(&p, &[], "false-test").unwrap();
        let out = run(&inv).await.unwrap();
        assert_ne!(out.status, 0);
        let err = run_ok(&inv).await.unwrap_err();
        assert!(matches!(err, Error::Exec { .. }));
        assert_eq!(err.code(), "exec");
    }

    #[tokio::test]
    async fn timeout_kills_and_reports() {
        let p = sleep_program();
        let inv = Invocation::with_options(
            &p,
            &["30"],
            Duration::from_millis(200),
            DEFAULT_MAX_OUTPUT,
            "sleep-test",
        )
        .unwrap();
        let err = run(&inv).await.unwrap_err();
        match err {
            Error::Timeout { elapsed_ms, .. } => {
                assert!(elapsed_ms < 5000, "超时应立即返回，实测 {elapsed_ms}ms")
            }
            other => panic!("期望 Timeout，得到 {other:?}"),
        }
        assert_eq!(err.code(), "timeout");
    }

    #[tokio::test]
    async fn large_output_is_capped_without_deadlock() {
        // 生成 2 MiB 输出：必须被截断且不会因管道写满而卡死。
        let dd = resolve_program(&["/bin/dd", "/usr/bin/dd"]);
        let cat = cat_program();
        let file = std::env::temp_dir().join(format!("smw-exec-{}", std::process::id()));
        if let Some(ddp) = dd {
            let mk = Invocation::with_options(
                &ddp,
                &[
                    "if=/dev/zero",
                    &format!("of={}", file.display()),
                    "bs=1024",
                    "count=2048",
                ],
                Duration::from_secs(5),
                4096,
                "dd",
            )
            .unwrap();
            run_ok(&mk).await.unwrap();
            let inv = Invocation::with_options(
                &cat,
                &[&file.display().to_string()],
                Duration::from_secs(10),
                1024,
                "cat",
            )
            .unwrap();
            let out = run(&inv).await.unwrap();
            assert_eq!(out.stdout.len(), 1024);
            assert!(out.stdout_truncated);
            let _ = std::fs::remove_file(&file);
        } else {
            eprintln!("跳过：测试环境无 dd");
        }
    }

    #[tokio::test]
    async fn missing_program_gives_exec_error_not_panic() {
        // 白名单内但设备上不存在的路径。
        let inv = Invocation::new("/bin/smw-definitely-missing", &[], "ghost").unwrap();
        let err = run(&inv).await.unwrap_err();
        assert!(matches!(err, Error::Exec { .. }), "{err:?}");
        // 白名单外的路径必须在构造阶段就被拒绝，绝不能走到 spawn。
        let denied = Invocation::new("/usr/sbin/definitely-missing-nft", &[], "ghost");
        assert!(matches!(denied, Err(Error::Permission(_))), "{denied:?}");
    }
}
