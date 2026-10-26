//! nftables 数据面：`table inet smw` 的程序生成、能力探测、原子应用与回滚。
//!
//! # 为什么这个模块一半是「纯文本生成」、一半是「进程调用」
//!
//! 数据面的正确性最终只能在真实设备上由 `nft` 自己判定。因此这里把职责切开：
//!
//! * [`build()`] 等纯函数只负责生成 nft 脚本文本和元数据（标签、集合名、可热替换的
//!   规则体），完全可单测，不依赖 root、不依赖 `nft` 二进制；
//! * [`Nft`] 是很薄的一层执行器：写临时脚本 → `nft -c -f`（**先校验**）→ `nft -f`
//!   （**原子提交**）→ `nft -a list`（**后校验**）。任何一步失败都返回明确错误，
//!   由 [`crate::transaction`] 决定回滚；这里绝不「忽略错误继续跑」。
//!
//! # 与 firewall4 / SQM / 其它插件共存
//!
//! `ct mark` 是全局共享资源。本模块的所有权判定基于 [`crate::marks`] 的魔数区间，
//! 写成 nft 原生支持的**区间匹配**（不用位运算表达式，兼容性更弱）：
//!
//! ```text
//! ct mark 0x05000000-0x05ffffff   →  本插件的已建连接：继承到 pktmark
//! ct mark != 0                    →  别人的标记：完全不动，让它按自己的策略走
//! meta mark != 0                  →  已被别人（如 SQM）打上 pktmark：也不动
//! ```
//!
//! 「宁可少做」是有意的：抢别人的出口决策会产生难以排查的不对称路由，
//! 而不介入最多是让那条连接走 main 表。
//!
//! # 不做高频全量重建
//!
//! 配置变更（低频）：一次 `delete table inet smw` + 重新声明，单批次原子提交，
//! 只动自己的表，绝不 flush 别人的表。
//! 桶→线路重排（高频，默认每几秒）：只按 handle 替换 `smw:bucket:*` 这几条规则
//! （[`Nft::replace_rule`]），规则数量恒定，不重建集合、不重建链。
//!
//! # 设备侧待验证事项（诚实清单）
//!
//! 沙箱内没有 `nft` 二进制，以下语法由能力探测（[`probe_scripts`]）在设备上实测：
//! `jhash ... map`、`th sport/dport`、`type route hook output`、`flags dynamic,timeout`
//! 集合、`type ether_addr` 集合、规则 `comment`。探测不通过的语法**不会**被写进程序，
//! 而是变成 `Issue::Warning` 说明该能力已降级。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use crate::config::schema::{Algorithm, ProtoFilter};
use crate::config::validate::{Issue, Severity};
use crate::marks;
use crate::system::exec::{self, Invocation};
use crate::system::netlink::Family;
use crate::{logging, Error, Result, NS};

/// 本插件独占的 nft 表名（`table inet smw`）。
pub const TABLE: &str = NS;
pub const CHAIN_PREROUTING: &str = "prerouting";
pub const CHAIN_OUTPUT: &str = "output";

/// mangle 位置的 hook 优先级：在 conntrack（-200）之后、路由决策之前，
/// 因此 `ct state`/`ct mark` 可用，且标记能影响选表。
pub const HOOK_PRIO: i32 = -150;

/// 单个集合允许的元素上限：防止域名规则无界增长吃掉设备内存。
pub const MAX_SET_ELEMENTS: usize = 2048;
/// 动态（DNS 派生）集合的容量：nft 要求 `flags dynamic` 的集合显式给出 size。
pub const DYNAMIC_SET_SIZE: u32 = 1024;

/// 规则标签前缀，`nft -a list` 之后据此找 handle。
pub const TAG_INHERIT: &str = "smw:inherit";
pub const TAG_FOREIGN_CT: &str = "smw:foreign-ctmark";
pub const TAG_FOREIGN_PKT: &str = "smw:foreign-pktmark";
pub const TAG_NOT_LAN: &str = "smw:not-lan";
pub const TAG_NOT_NEW: &str = "smw:not-new";
pub const TAG_NO_LAN: &str = "smw:no-lan-devices";
pub const TAG_OUT_INHERIT: &str = "smw:out-inherit";

/// 一次分类规则（游戏/普通桶）的期望信息，应用后用于校验。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tag {
    /// nft 规则 comment 全文。
    pub comment: String,
    pub chain: &'static str,
}

/// 可热替换的桶规则（一次重排只替换这几条）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BucketBody {
    pub chain: &'static str,
    pub comment: String,
    /// 规则体全文（不含 `handle`），`nft replace rule ... handle N <body>` 直接用。
    pub body: String,
}

/// nft 对象名必须安全：只允许 `[A-Za-z0-9_.-]`，且不以 `-` 开头。
///
/// 这是**边界校验**，不是「给 shell 加引号」——生成的文本走 `nft -f 文件`，
/// 但对象名一旦被污染，语义就变成了别人的对象，所以必须硬拒。
fn safe_name(kind: &str, raw: &str, max: usize) -> Result<String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err(Error::Config(format!("{kind} 名称为空")));
    }
    if s.len() > max {
        return Err(Error::Config(format!(
            "{kind} 名称过长（>{max}）：{}",
            s.len()
        )));
    }
    if s.starts_with('-') {
        return Err(Error::Config(format!("{kind} 名称不能以 '-' 开头：{s}")));
    }
    if !s
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
    {
        return Err(Error::Config(format!(
            "{kind} 名称含非法字符（只允许字母数字 _ . -）：{s}"
        )));
    }
    Ok(s.to_string())
}

/// 需要出现在引号里的字符串（接口名、comment）：拒绝引号/反斜杠/换行/控制字符。
fn safe_quoted(kind: &str, raw: &str) -> Result<String> {
    if raw.contains('"') || raw.contains('\\') || raw.contains('\n') || raw.contains('\t') {
        return Err(Error::Config(format!(
            "{kind} 含引号/转义/换行，拒绝写入 nft 脚本：{raw:?}"
        )));
    }
    if raw.chars().any(|c| (c as u32) < 0x20) {
        return Err(Error::Config(format!("{kind} 含控制字符：{raw:?}")));
    }
    Ok(raw.to_string())
}

/// 一条 WAN 线路在数据面上的身份。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub name: String,
    pub slot: u8,
}

/// 一条游戏规则的 nft 表达所需材料（由 `rules` 层从 UCI 预处理而来）。
///
/// 目的网段/客户端网段必须已经过 `config::validate` 校验，这里只做名称安全检查；
/// `dns_set` 为 `Some` 表示该规则含域名条件，需要动态集合（由 `rules::dns_sets` 填充）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameSpec {
    pub name: String,
    /// nft 对象名后缀（已 slug 化）。
    pub slug: String,
    /// 数值小者先匹配；相同则按名称字典序（由 `rules` 层排好序后传入）。
    pub priority: u16,
    /// 命中后写入的完整标记（含 `CLASS_GAME`）。
    pub mark: u32,
    pub v4: Vec<String>,
    pub v6: Vec<String>,
    pub macs: Vec<String>,
    pub client_v4: Vec<String>,
    pub client_v6: Vec<String>,
    /// 端口/范围文本，如 `443`、`8000-8010`。空表示不限端口。
    pub ports: Vec<String>,
    pub proto: ProtoFilter,
    /// 动态 DNS 集合名（`None` 表示该规则不含域名条件）。
    pub dns_set: Option<String>,
    /// 集合元素过期时间（秒），来自 DNS TTL 下限。
    pub dns_timeout_s: u64,
}

/// 设备能力。全部由 [`probe_scripts`] 在实际设备上用 `nft -c` 测出。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capabilities {
    pub nft_exists: bool,
    pub version: String,
    /// `meta mark set jhash <concat> mod N map { ... }`
    pub jhash_map: bool,
    /// `ct mark 0x05000000-0x05ffffff` 区间匹配
    pub ct_mark_range: bool,
    /// `meta l4proto { tcp, udp } ... th sport/dport`
    pub th_payload: bool,
    /// `flags dynamic,timeout` + `add element ... timeout`
    pub dyn_timeout_sets: bool,
    /// `type route hook output priority`（影响路由器本机流量的回程标记）
    pub route_hook_output: bool,
    /// `set ... { type ether_addr }`
    pub ether_sets: bool,
    /// 规则 `comment "..."`（handle 定位依赖它）
    pub comments: bool,
    /// `jhash` 是否接受额外种子/偏移参数（绝大多数 nft 版本不接受）
    pub jhash_seed: bool,
}

impl Default for Capabilities {
    /// 保守默认：除了最基础的部分，其它都当作「未验证为可用」。
    /// 这样在探测失败/未探测时，程序不会写出高风险语法。
    fn default() -> Self {
        Capabilities {
            nft_exists: false,
            version: String::new(),
            jhash_map: true,
            ct_mark_range: true,
            th_payload: true,
            dyn_timeout_sets: false,
            route_hook_output: false,
            ether_sets: true,
            comments: true,
            jhash_seed: false,
        }
    }
}

/// 能力探测脚本：每个都用一次性表 `inet smwprobe`，`nft -c` 只做校验不提交，
/// 因此对现网零影响。
pub fn probe_scripts() -> Vec<(&'static str, String, &'static str)> {
    let head = "table inet smwprobe {\n\tchain c {\n\t\ttype filter hook prerouting priority ";
    let prio = format!("{HOOK_PRIO}; policy accept;\n");
    // 注意 `}}` 才是格式字符串里的一个字面 `}`：写成 `{{}}` 会产出 `{}` 两个字面量，
    // 整条脚本就以 `{}` 收尾而不是 `}`，nft 报 `unexpected '}'` —— 这条曾让**每一条**
    // mk() 探测都失败（真机上表现为大面积假降级），回归测试锁死收尾形状。
    let mk = |body: &str| -> String { format!("{head}{prio}{body}\t}}\n}}\n") };
    vec![
        (
            "jhash_map",
            mk("\t\tmeta mark set jhash ip saddr . ip daddr mod 2 map { 0 : 0x05000001, 1 : 0x05000002 }\n"),
            "jhash + 内联 map（分桶选路的基础）",
        ),
        (
            "ct_mark_range",
            mk(&format!(
                "\t\tct mark {} meta mark set ct mark accept\n",
                marks::own_range_text()
            )),
            "ct mark 区间匹配（所有权判定）",
        ),
        (
            "th_payload",
            mk("\t\tmeta l4proto { tcp, udp } th dport 443 accept\n"),
            "th sport/th dport 跨协议端口匹配",
        ),
        (
            "dyn_timeout_sets",
            "table inet smwprobe {\n\tset s {\n\t\ttype ipv4_addr\n\t\tflags dynamic,timeout\n\t\tsize 64\n\t\tpolicy warn\n\t}\n\tchain c {\n\t\ttype filter hook prerouting priority -150; policy accept;\n\t\tip daddr @s accept\n\t}\n\tadd element inet smwprobe s { 192.0.2.1 timeout 30s }\n}\n".to_string(),
            "dynamic+timeout 集合（域名规则依赖）",
        ),
        (
            "route_hook_output",
            "table inet smwprobe {\n\tchain o {\n\t\ttype route hook output priority -150; policy accept;\n\t\tmeta mark set ct mark\n\t}\n}\n".to_string(),
            "type route hook output（本机流量重新查路由）",
        ),
        (
            "ether_sets",
            "table inet smwprobe {\n\tset m {\n\t\ttype ether_addr\n\t}\n\tchain c {\n\t\ttype filter hook prerouting priority -150; policy accept;\n\t\tether saddr @m accept\n\t}\n}\n".to_string(),
            "type ether_addr 集合（按 MAC 匹配客户端）",
        ),
        (
            "comments",
            mk("\t\tct state new accept comment \"smw:probe\"\n"),
            "规则 comment（handle 定位依赖它）",
        ),
        (
            "jhash_seed",
            mk("\t\tmeta mark set jhash ip saddr 0x1234 mod 2 map { 0 : 0x05000001, 1 : 0x05000002 }\n"),
            "jhash 偏移/种子参数（hash_seed 生效的前提）",
        ),
    ]
}

/// 探测结果 → 能力表。
///
/// `ok` 是探测通过的键名列表（来自 [`probe_scripts`] 的返回值）。
pub fn capabilities_from_probe(version: &str, ok: &[String]) -> Capabilities {
    let enabled = |k: &str| ok.iter().any(|x| x == k);
    let ct_mark_range = enabled("ct_mark_range");
    Capabilities {
        nft_exists: true,
        version: version.to_string(),
        jhash_map: enabled("jhash_map") && ct_mark_range,
        ct_mark_range,
        th_payload: enabled("th_payload"),
        dyn_timeout_sets: enabled("dyn_timeout_sets"),
        route_hook_output: enabled("route_hook_output"),
        ether_sets: enabled("ether_sets"),
        comments: enabled("comments"),
        jhash_seed: enabled("jhash_seed"),
    }
}

/// 在设备上做一次能力探测，返回可直接交给 [`build`] 的能力表。
///
/// 每条探测脚本都以一次性表 `inet smwprobe` 为目标、只走 `nft -c`（试算不提交），
/// 因此对现网零副作用；这也是「语法可用性只能在真机证实」这件事唯一的落地方式
/// （沙箱里没有 `nft`，也没有 netfilter）。
///
/// 单条探测失败**不是错误**：它只表示该语法在本机不用，程序会走降级路径，
/// 降级说明由 [`build`] 写进 `Program::issues`，必须让用户看得见。
/// 失败清单同时进日志，否则「为什么游戏域名规则没生效」这类问题无从下手。
pub async fn probe_caps(nft: &Nft) -> Capabilities {
    let version = match nft.version().await {
        Some(v) if !v.trim().is_empty() => crate::clamp_str(v.trim(), 80),
        _ => {
            // 版本号只用于诊断，拿不到不该放弃整轮探测；但必须留痕，
            // 否则 UI 上「版本：空」会被误读成「没装 nft」。
            logging::warn_ctx(
                "firewall",
                "version",
                "nft --version 未取得版本号，能力探测继续（版本号仅用于诊断）",
                &[],
            );
            String::new()
        }
    };
    let scripts = probe_scripts();
    let mut ok: Vec<String> = Vec::new();
    let mut failed: Vec<String> = Vec::new();
    for (key, script, desc) in &scripts {
        match nft.check(script).await {
            Ok(()) => ok.push((*key).to_string()),
            Err(e) => failed.push(format!(
                "{key}（{desc}）：{}",
                crate::clamp_str(&e.to_string(), 160)
            )),
        }
    }
    if failed.is_empty() {
        logging::info_ctx(
            "firewall",
            "capabilities",
            &format!("能力探测通过 {}/{} 项", ok.len(), scripts.len()),
            &[("version", version.clone())],
        );
    } else {
        logging::warn_ctx(
            "firewall",
            "capabilities",
            &format!(
                "{}/{} 项语法在本设备不可用，nft 程序将按降级路径生成：{}",
                failed.len(),
                scripts.len(),
                crate::clamp_str(&failed.join("；"), 512)
            ),
            &[("version", version.clone())],
        );
    }
    capabilities_from_probe(&version, &ok)
}

/// 构造 nft 程序的输入。
pub struct Input<'a> {
    pub algorithm: Algorithm,
    /// 桶数量（`global.buckets`）。
    pub buckets: u16,
    /// 桶 → 槽位映射，长度必须等于 `buckets`；`0` 表示该桶不标记（不分流）。
    pub bucket_map: &'a [u8],
    /// 代际，写进标记的 bit12..15，仅用于观测。
    pub gen: u8,
    /// `hash_seed`，仅在 `caps.jhash_seed` 为真时写入。
    pub hash_seed: u32,
    /// 是否继承 ct mark（`global.conn_sticky`）。
    pub conn_sticky: bool,
    pub families: &'a [Family],
    pub lan_ifaces: &'a [String],
    pub lines: &'a [Line],
    pub games: &'a [GameSpec],
    pub protected_v4: &'a [String],
    pub protected_v6: &'a [String],
    pub bypass_v4: &'a [String],
    pub bypass_v6: &'a [String],
    pub caps: &'a Capabilities,
}

/// 生成结果。
#[derive(Debug, Clone, Default)]
pub struct Program {
    /// 完整脚本（单批次：delete table + 声明 + 元素）。
    pub text: String,
    /// 期望存在的规则标签，`apply_and_verify` 据此核对。
    pub tags: Vec<Tag>,
    /// 可热替换的桶规则体。
    pub buckets: Vec<BucketBody>,
    /// 本程序创建的全部集合名（卸载/清理时用）。
    pub sets: Vec<String>,
    /// 生成过程中的告警与降级说明，必须显示给用户。
    pub issues: Vec<Issue>,
    /// 人类可读摘要，用于「应用前变更摘要」。
    pub summary: String,
}

fn warn(path: &str, msg: String, hint: Option<String>) -> Issue {
    Issue {
        severity: Severity::Warning,
        path: path.to_string(),
        message: msg,
        hint,
    }
}

fn info(path: &str, msg: String, hint: Option<String>) -> Issue {
    Issue {
        severity: Severity::Info,
        path: path.to_string(),
        message: msg,
        hint,
    }
}

/// 只保留某地址族的元素（文本已经过校验，这里按是否含 `:` 分拣）。
fn family_elems(items: &[String], family: Family) -> Vec<String> {
    items
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .filter(|s| {
            let v6 = s.contains(':');
            match family {
                Family::V4 => !v6,
                Family::V6 => v6,
            }
        })
        .collect()
}

/// 集合元素文本：CIDR 与主机地址统一带前缀长度，避免 nft 推断差异。
fn normalized_elem(s: &str) -> String {
    if s.contains('/') {
        return s.to_string();
    }
    match s.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(_)) => format!("{s}/32"),
        Ok(std::net::IpAddr::V6(_)) => format!("{s}/128"),
        Err(_) => s.to_string(),
    }
}

/// 集合声明块。`elements` 为空时省略 `elements=` 行（`{ }` 在部分版本上是语法错误）。
fn set_block(name: &str, ty: &str, extra: &[String], elements: &[String]) -> String {
    let mut s = format!("\tset {name} {{\n\t\ttype {ty}\n");
    for e in extra {
        s.push_str(&format!("\t\t{e}\n"));
    }
    if !elements.is_empty() {
        s.push_str(&format!("\t\telements = {{ {} }}\n", elements.join(", ")));
    }
    s.push_str("\t}\n");
    s
}

/// 算法 → 哈希表达式（按族）。返回 `(选择器前缀, 表达式)`；
/// 返回 `None` 表示该算法不由 nft 桶规则实现（见 `build` 里的能力门控）。
fn hash_expr(
    alg: Algorithm,
    family: Family,
    ports: bool,
    caps: &Capabilities,
) -> Option<(String, String)> {
    use Family::*;
    let (saddr, daddr, proto) = match (family, ports) {
        (V4, true) => ("ip saddr", "ip daddr", ""),
        (V4, false) => ("ip saddr", "ip daddr", ""),
        (V6, true) => ("ip6 saddr", "ip6 daddr", ""),
        (V6, false) => ("ip6 saddr", "ip6 daddr", ""),
    };
    let _ = proto;
    let sel = if ports {
        if !caps.th_payload {
            return None;
        }
        "meta l4proto { tcp, udp } ".to_string()
    } else {
        String::new()
    };
    let expr = match alg {
        Algorithm::SrcIp => saddr.to_string(),
        Algorithm::SrcIpSrcPort if ports => format!("{saddr} . th sport"),
        Algorithm::SrcIpSrcPort => saddr.to_string(),
        Algorithm::SrcIpDstIp
        | Algorithm::LeastNewConnections
        | Algorithm::LeastTraffic
        | Algorithm::WeightedHash => {
            format!("{saddr} . {daddr}")
        }
        Algorithm::SrcIpDstIpDstPort if ports => format!("{saddr} . {daddr} . th dport"),
        Algorithm::SrcIpDstIpDstPort => format!("{saddr} . {daddr}"),
        Algorithm::FullFiveTuple if ports => match family {
            V4 => format!("ip protocol . {saddr} . th sport . {daddr} . th dport"),
            V6 => format!("meta l4proto . {saddr} . th sport . {daddr} . th dport"),
        },
        Algorithm::FullFiveTuple => format!("{saddr} . {daddr}"),
        // 由内核 nexthop 权重决定出口，不需要 nft 分桶。
        Algorithm::WeightedEcmp => return None,
    };
    Some((sel, expr))
}

/// 生成桶规则体（含选择器与 verdict），供 `build` 与热替换共用。
///
/// 参数收成一个 `&Input` 而不是 9 个位置参数：这些值本来就同源，拆开传既容易在调用点
/// 写错顺序（`gen` 与 `seed` 同为整数，换位不会报错），也让签名难以演进。
fn bucket_rule(
    input: &Input<'_>,
    family: Family,
    chain: &'static str,
    tag: &str,
) -> Option<BucketBody> {
    let alg = input.algorithm;
    let caps = input.caps;
    let buckets = input.buckets;
    let ports = matches!(
        alg,
        Algorithm::SrcIpSrcPort | Algorithm::SrcIpDstIpDstPort | Algorithm::FullFiveTuple
    );
    // 端口参与的算法：先出「有端口」的规则，未命中（其它协议）再落到无端口版本。
    let (sel, expr) = hash_expr(alg, family, ports && caps.th_payload, caps)?;
    let mut map_txt = String::from("{ ");
    // `build()` 已校验 bucket_map 长度等于 buckets，因此枚举下标即桶号。
    for (b, &slot) in input.bucket_map.iter().enumerate() {
        let mark = if slot == 0 {
            0u32
        } else {
            marks::mark(slot, marks::CLASS_NORMAL, input.gen, b as u16)
        };
        map_txt.push_str(&format!("{b} : {}, ", marks::hex(mark)));
    }
    map_txt.push('}');
    let seed_txt = if caps.jhash_seed && input.hash_seed != 0 {
        format!(" 0x{:08x}", input.hash_seed)
    } else {
        String::new()
    };
    let body = format!(
        "meta mark == 0 ct state new {sel}meta mark set jhash {expr}{seed_txt} mod {buckets} map {map_txt} ct mark set meta mark accept comment \"{tag}\""
    );
    Some(BucketBody {
        chain,
        comment: tag.to_string(),
        body,
    })
}

/// 生成完整 nft 程序。
pub fn build(input: &Input) -> Result<Program> {
    let mut p = Program::default();
    let caps = input.caps;
    let mut chain_rules: Vec<String> = Vec::new();
    let mut out_rules: Vec<String> = Vec::new();
    let mut issues: Vec<Issue> = Vec::new();

    if input.bucket_map.len() != input.buckets as usize {
        return Err(Error::Config(format!(
            "桶映射长度 {} 与桶数 {} 不一致",
            input.bucket_map.len(),
            input.buckets
        )));
    }
    if input.buckets < 2 || input.buckets > marks::BUCKETS {
        return Err(Error::Config(format!(
            "桶数 {} 超出可用范围 2..={}",
            input.buckets,
            marks::BUCKETS
        )));
    }
    for l in input.lines {
        if l.slot == 0 || l.slot > marks::MAX_WANS {
            return Err(Error::Config(format!(
                "线路 {} 的槽位 {} 非法（应为 1..={}）",
                l.name,
                l.slot,
                marks::MAX_WANS
            )));
        }
    }
    for b in input.bucket_map {
        if *b != 0 && !input.lines.iter().any(|l| l.slot == *b) {
            return Err(Error::Config(format!("桶映射引用了未知槽位 {b}")));
        }
    }

    // ---- 集合：保护/旁路 ----
    let mut decl = String::new();
    for (fam, items, name) in [
        (Family::V4, input.protected_v4, "smw_protected_v4"),
        (Family::V6, input.protected_v6, "smw_protected_v6"),
        (Family::V4, input.bypass_v4, "smw_bypass_v4"),
        (Family::V6, input.bypass_v6, "smw_bypass_v6"),
    ] {
        if !input.families.contains(&fam) {
            continue;
        }
        let mut elems: Vec<String> = family_elems(items, fam)
            .into_iter()
            .map(|x| normalized_elem(&x))
            .collect();
        elems.sort();
        elems.dedup();
        if elems.len() > MAX_SET_ELEMENTS {
            return Err(Error::Config(format!(
                "集合 {name} 元素 {} 超过上限 {MAX_SET_ELEMENTS}",
                elems.len()
            )));
        }
        decl.push_str(&set_block(
            name,
            if fam == Family::V4 {
                "ipv4_addr"
            } else {
                "ipv6_addr"
            },
            &[
                "flags interval".to_string(),
                format!("comment \"{}\"", name),
            ],
            &elems,
        ));
        p.sets.push(name.to_string());
    }

    // ---- 链：prerouting ----
    if input.conn_sticky {
        if caps.ct_mark_range {
            chain_rules.push(format!(
                "ct mark {} meta mark set ct mark accept comment \"{TAG_INHERIT}\"",
                marks::own_range_text()
            ));
        } else {
            issues.push(warn(
                "smartmwan.global.conn_sticky",
                "设备 nft 不支持 ct mark 区间匹配，已关闭标记继承".into(),
                Some("每条新建连接都会被重新分类，已建立连接可能中途换出口".into()),
            ));
        }
    } else {
        issues.push(warn(
            "smartmwan.global.conn_sticky",
            "已显式关闭 ct mark 继承（conn_sticky=0）".into(),
            Some("重排桶时活动连接会换出口，可能造成游戏掉线/不对称路由".into()),
        ));
    }
    // 别人的标记一律不介入：没有区间匹配能力时这条也必须写（用 != 0 兜底）。
    chain_rules.push(format!("ct mark != 0 accept comment \"{TAG_FOREIGN_CT}\""));
    chain_rules.push(format!(
        "meta mark != 0 accept comment \"{TAG_FOREIGN_PKT}\""
    ));

    let lan: Vec<String> = input
        .lan_ifaces
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if lan.is_empty() {
        // 没有 LAN 设备就不分类，绝不能退化成「对所有接口分类」——
        // 那会把 WAN 侧入站流量也打上标记，直接改变转发行为。
        //
        // 但「不分类」的意思是**不加标记规则**，不是 drop：prerouting 里的裸 drop
        // 会断掉包括管理面在内的全部流量，把一个配置解析问题放大成全网瘫痪。
        // 这里用 counter：流量原样走 main 表（= 插件安装前的行为），
        // 同时标签留在链里，`nft list` 与事务复核都能看见这个状态。
        chain_rules.push(format!("counter comment \"{TAG_NO_LAN}\""));
        issues.push(warn(
            "smartmwan.global.lan_zones",
            "未能确定 LAN 接口，nft 分类规则已全部停用".into(),
            Some("检查 firewall 里 LAN zone 的 network 列表是否指向本插件识别的接口".into()),
        ));
    } else {
        let mut quoted: Vec<String> = Vec::new();
        for d in &lan {
            quoted.push(format!("\"{}\"", safe_quoted("LAN 接口名", d)?));
        }
        chain_rules.push(format!(
            "iifname != {{ {} }} accept comment \"{TAG_NOT_LAN}\"",
            quoted.join(", ")
        ));
    }
    chain_rules.push(format!("ct state != new accept comment \"{TAG_NOT_NEW}\""));

    for (fam, name, tag) in [
        (Family::V4, "smw_protected_v4", "smw:protected-src:v4"),
        (Family::V6, "smw_protected_v6", "smw:protected-src:v6"),
        (Family::V4, "smw_bypass_v4", "smw:bypass-dst:v4"),
        (Family::V6, "smw_bypass_v6", "smw:bypass-dst:v6"),
    ] {
        if !input.families.contains(&fam) || !p.sets.contains(&name.to_string()) {
            continue;
        }
        let (key, _) = match fam {
            Family::V4 => ("ip", "saddr"),
            Family::V6 => ("ip6", "saddr"),
        };
        let field = if tag.contains("src") {
            "saddr"
        } else {
            "daddr"
        };
        chain_rules.push(format!("{key} {field} @{name} accept comment \"{tag}\""));
        // 每条带 comment 的规则都必须登记进 tags：事务层用 tags 与内核实际规则做集合比对，
        // 漏登记会在复核时报「多余标签」，把一次本来正确的提交判成失败。
        p.tags.push(Tag {
            comment: tag.to_string(),
            chain: CHAIN_PREROUTING,
        });
    }

    // ---- 游戏/客户端规则（按 priority 已排序）----
    if !lan.is_empty() {
        for g in input.games {
            let slug = safe_name("游戏规则", &g.slug, 40)?;
            let tag = format!("smw:game:{slug}");
            let mut matchers: Vec<String> = Vec::new();

            if !g.macs.is_empty() {
                if !caps.ether_sets {
                    // 注意：这里**不是**「降级为不匹配」，而是「这个条件消失了」——
                    // 少一个匹配项等于放宽匹配面。所以只在还有其它客户端条件可用时才允许继续，
                    // 下面的 wants_client/matchers.is_empty() 闸门负责兜住整条规则。
                    issues.push(warn(
                        &format!("smartmwan.game[{slug}].client_macs"),
                        "设备 nft 不支持 ether_addr 集合，本规则的 MAC 条件无法生效".into(),
                        Some("改用客户端 IP 匹配，或升级 nft；否则本条规则不会下发".into()),
                    ));
                } else {
                    let name = format!("smw_g_{slug}_mac");
                    let mut el: Vec<String> =
                        g.macs.iter().map(|m| m.to_ascii_lowercase()).collect();
                    el.sort();
                    el.dedup();
                    decl.push_str(&set_block(&name, "ether_addr", &[], &el));
                    p.sets.push(name.clone());
                    // 选择器必须带字段名（`ether saddr @set`），不能只写裸 `@set`：
                    // 裸集合引用不带字段，和后面的 `ip saddr`/`ip6 saddr` 混排时语义不明，
                    // 且历史上这里的拼接会把以 `@` 开头的匹配项整条丢掉 ——
                    // MAC 条件于是静默失效，一条「只针对这台主机」的规则
                    // 退化成命中范围内全部新建连接。这类静默放宽比直接报错危险得多。
                    // 现在匹配项一律带字段名，拼接处也不再做任何过滤。
                    matchers.push(format!("ether saddr @{name}"));
                }
            }
            let mut v4_cli = family_elems(&g.client_v4, Family::V4)
                .into_iter()
                .map(|x| normalized_elem(&x))
                .collect::<Vec<_>>();
            let mut v6_cli = family_elems(&g.client_v6, Family::V6)
                .into_iter()
                .map(|x| normalized_elem(&x))
                .collect::<Vec<_>>();
            v4_cli.sort();
            v4_cli.dedup();
            v6_cli.sort();
            v6_cli.dedup();
            if !v4_cli.is_empty() {
                let name = format!("smw_g_{slug}_cli4");
                decl.push_str(&set_block(
                    &name,
                    "ipv4_addr",
                    &["flags interval".into()],
                    &v4_cli,
                ));
                p.sets.push(name.clone());
                matchers.push(format!("ip saddr @{name}"));
            }
            if !v6_cli.is_empty() && input.families.contains(&Family::V6) {
                let name = format!("smw_g_{slug}_cli6");
                decl.push_str(&set_block(
                    &name,
                    "ipv6_addr",
                    &["flags interval".into()],
                    &v6_cli,
                ));
                p.sets.push(name.clone());
                matchers.push(format!("ip6 saddr @{name}"));
            }
            // 客户端条件闸门：规则**想**限定主机（写了 MAC 或客户端 IP），但一个可用匹配项都没
            // 剩下时（MAC 集合不被支持；或只有 IPv6 客户端条件而本机 IPv6 未启用），
            // 必须**整条不下发**。少一个条件等于把匹配面放宽到全 LAN 的新建连接 ——
            // 这比「规则不生效」严重得多，与前面修掉的 MAC 过滤、域名兜底是同一类缺陷。
            let wants_client =
                !g.macs.is_empty() || !g.client_v4.is_empty() || !g.client_v6.is_empty();
            if wants_client && matchers.is_empty() {
                issues.push(warn(
                    &format!("smartmwan.game[{slug}]"),
                    "客户端条件全部无法生效（MAC 集合不被支持，或仅有 IPv6 客户端条件而 IPv6 未启用），本条规则不下发".into(),
                    Some("补一条 IPv4 客户端条件，或在设备上启用 IPv6 / 升级 nft".into()),
                ));
                continue;
            }
            let mut v4_dst = family_elems(&g.v4, Family::V4)
                .into_iter()
                .map(|x| normalized_elem(&x))
                .collect::<Vec<_>>();
            let mut v6_dst = family_elems(&g.v6, Family::V6)
                .into_iter()
                .map(|x| normalized_elem(&x))
                .collect::<Vec<_>>();
            v4_dst.sort();
            v4_dst.dedup();
            v6_dst.sort();
            v6_dst.dedup();
            let has_dst = !v4_dst.is_empty() || !v6_dst.is_empty() || g.dns_set.is_some();
            if !v4_dst.is_empty() {
                let name = format!("smw_g_{slug}_dst4");
                if v4_dst.len() > MAX_SET_ELEMENTS {
                    return Err(Error::Config(format!("规则 {slug} 目标数超过上限")));
                }
                decl.push_str(&set_block(
                    &name,
                    "ipv4_addr",
                    &["flags interval".into()],
                    &v4_dst,
                ));
                p.sets.push(name.clone());
            }
            if !v6_dst.is_empty() && input.families.contains(&Family::V6) {
                let name = format!("smw_g_{slug}_dst6");
                decl.push_str(&set_block(
                    &name,
                    "ipv6_addr",
                    &["flags interval".into()],
                    &v6_dst,
                ));
                p.sets.push(name.clone());
            }
            if !has_dst {
                // 无目标条件时，若还有客户端条件，就等价于「这些主机的全部新连接」。
                issues.push(info(
                    &format!("smartmwan.game[{slug}]"),
                    "该规则没有目标网段/域名条件，命中范围为客户端侧全部新建连接".into(),
                    None,
                ));
            }

            // 协议与端口
            let mut l4: Vec<String> = Vec::new();
            let ports_ok = !g.ports.is_empty();
            match g.proto {
                ProtoFilter::Tcp => l4.push("meta l4proto tcp".into()),
                ProtoFilter::Udp => l4.push("meta l4proto udp".into()),
                ProtoFilter::Both if ports_ok => l4.push("meta l4proto { tcp, udp }".into()),
                ProtoFilter::Both => {}
            }
            if ports_ok && caps.th_payload {
                let mut ps: Vec<String> = Vec::new();
                for raw in &g.ports {
                    let s = raw.trim();
                    // 端口文本必须已经是「数字或 数字-数字」形态；其它字符一律拒绝。
                    let ok = s
                        .split('-')
                        .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()));
                    if !ok {
                        return Err(Error::Config(format!("规则 {slug} 端口写法非法：{raw}")));
                    }
                    ps.push(s.to_string());
                }
                ps.sort();
                ps.dedup();
                l4.push(format!("th dport {{ {} }}", ps.join(", ")));
            } else if ports_ok {
                issues.push(warn(
                    &format!("smartmwan.game[{slug}].ports"),
                    "设备 nft 不支持 th dport，该规则的端口条件已忽略".into(),
                    Some("规则会匹配该主机的全部新建连接，范围偏大".into()),
                ));
            }

            let mark_txt = marks::hex(g.mark);
            if g.mark == 0 {
                return Err(Error::Config(format!(
                    "规则 {slug} 的标记为 0，会退化为不分流"
                )));
            }
            // 目的匹配按族拆成规则，避免 inet 链里混用 ip/ip6 选择器。
            //
            // 一个目的条件（固定网段集合 / DNS 动态集合）一条规则：nft 里
            // `ip daddr @{a}, @{b}` 这种写法跨版本不稳定，拆成多条更可靠，
            // 而且每条都能独立按 comment 定位（回滚与差量替换都靠它）。
            let mut fam_rules: Vec<(Option<String>, Option<Family>)> = Vec::new();
            let mut v4_dsts: Vec<String> = Vec::new();
            if !v4_dst.is_empty() {
                v4_dsts.push(format!("ip daddr @smw_g_{slug}_dst4"));
            }
            if let Some(dns) = &g.dns_set {
                if caps.dyn_timeout_sets {
                    let name = safe_name("DNS 集合", dns, 40)?;
                    decl.push_str(&set_block(
                        &name,
                        "ipv4_addr",
                        &[
                            "flags dynamic,timeout".into(),
                            format!("size {DYNAMIC_SET_SIZE}"),
                            "policy warn".into(),
                            format!("timeout {}s", g.dns_timeout_s.max(60)),
                            format!("comment \"smw:dns:{slug}\""),
                        ],
                        &[],
                    ));
                    p.sets.push(name.clone());
                    v4_dsts.push(format!("ip daddr @{name}"));
                } else {
                    issues.push(warn(
                        &format!("smartmwan.game[{slug}].domains"),
                        "设备 nft 不支持 dynamic+timeout 集合，该规则的域名条件无法生效".into(),
                        Some("改用固定网段，或升级 nft 到支持动态集合的版本".into()),
                    ));
                }
            }
            if v4_dsts.is_empty() {
                // 只有「本来就没有任何目的条件」时才下无目的规则。
                // 若是因为域名条件不被支持而变空，宁可一条都不下：
                // 兜底规则会命中该主机全部新建连接，那是比「不生效」严重得多的静默放宽。
                if g.dns_set.is_none() {
                    fam_rules.push((None, Some(Family::V4)));
                }
            } else {
                for d in v4_dsts {
                    fam_rules.push((Some(d), Some(Family::V4)));
                }
            }
            if input.families.contains(&Family::V6) {
                if !v6_dst.is_empty() {
                    fam_rules.push((
                        Some(format!("ip6 daddr @smw_g_{slug}_dst6")),
                        Some(Family::V6),
                    ));
                } else if v4_dst.is_empty() && g.dns_set.is_none() {
                    // 无目标条件时 IPv6 也照同一意图匹配客户端集合。
                    // 反过来说：只要 dns_set 存在就不给 v6 兜底 —— 域名集合目前是
                    // IPv4-only（解析的是 A 记录），兜底会变成「有域名规则却放行全部 v6」。
                    fam_rules.push((None, Some(Family::V6)));
                }
            }
            for (dst, fam) in fam_rules {
                let Some(fam) = fam else { continue };
                if !input.families.contains(&fam) {
                    continue;
                }
                let mut parts: Vec<String> = Vec::new();
                if let Some(d) = dst {
                    parts.push(d);
                }
                parts.extend(matchers.iter().cloned());
                parts.extend(l4.iter().cloned());
                parts.push("counter".into());
                parts.push(format!("meta mark set {mark_txt}"));
                parts.push("ct mark set meta mark".into());
                parts.push("accept".into());
                parts.push(format!("comment \"{tag}\""));
                let line = parts.join(" ");
                if line.len() > 4096 {
                    return Err(Error::Config(format!(
                        "规则 {slug} 文本过长（{} 字节）",
                        line.len()
                    )));
                }
                chain_rules.push(line);
                p.tags.push(Tag {
                    comment: tag.clone(),
                    chain: CHAIN_PREROUTING,
                });
            }
        }
    }

    // ---- 桶规则（热替换对象）----
    if !lan.is_empty()
        && input
            .lines
            .iter()
            .any(|l| input.bucket_map.contains(&l.slot))
    {
        for fam in input.families {
            if let Some(bb) = bucket_rule(
                input,
                *fam,
                CHAIN_PREROUTING,
                &format!(
                    "smw:bucket:{}",
                    match fam {
                        Family::V4 => "v4",
                        Family::V6 => "v6",
                    }
                ),
            ) {
                chain_rules.push(bb.body.clone());
                p.buckets.push(bb);
            } else if matches!(input.algorithm, Algorithm::WeightedEcmp) {
                issues.push(warn(
                    "smartmwan.global.algorithm",
                    "加权 ECMP 需要内核 nexthop 权重支持，本版本尚未实现".into(),
                    Some("请改用加权哈希（weighted_hash），行为等价且可观测".into()),
                ));
            } else {
                issues.push(warn(
                    "smartmwan.global.algorithm",
                    "设备 nft 不支持该算法所需的哈希/端口语法，普通流量不重新分桶".into(),
                    Some("退回按链路优先级选路（main 表）".into()),
                ));
            }
        }
    }

    // ---- output 链（本机流量的回程标记继承）----
    if caps.route_hook_output && input.conn_sticky && caps.ct_mark_range {
        out_rules.push(format!(
            "ct mark {} meta mark set ct mark accept comment \"{TAG_OUT_INHERIT}\"",
            marks::own_range_text()
        ));
    } else if caps.route_hook_output {
        issues.push(info(
            "smartmwan.global.conn_sticky",
            "未安装 output 链：路由器自身发出的回程包沿用内核默认决策".into(),
            None,
        ));
    } else {
        issues.push(info(
            "smartmwan",
            "设备不支持 type route hook output，本机流量的出口一致性只能依赖 main 表".into(),
            None,
        ));
    }

    // ---- 组装 ----
    let mut text = String::new();
    text.push_str("# smartmwand 生成的 nftables 程序，请勿手工编辑。\n");
    text.push_str("# 本批次只操作 table inet smw，绝不改动 fw4 的 table/链。\n");
    // 幂等删除三连：先声明（不存在则创建空表、存在则无操作），再删除，再正式声明。
    // 直接 `delete table inet smw` 在**表不存在**时整批失败
    // （`nft -c` 与 `nft -f` 都一样：Could not process rule: No such file or directory），
    // 那会让全新设备上的第一次提交永远死在试算阶段。这三行是一个原子批次，
    // 对「表在/不在」都成立。
    text.push_str(&format!("table inet {TABLE}\n"));
    text.push_str(&format!("delete table inet {TABLE}\n"));
    text.push_str(&format!("table inet {TABLE} {{\n"));
    text.push_str(&decl);
    text.push_str(&format!(
        "\tchain {CHAIN_PREROUTING} {{\n\t\ttype filter hook prerouting priority {HOOK_PRIO}; policy accept;\n"
    ));
    for r in &chain_rules {
        text.push_str(&format!("\t\t{r}\n"));
    }
    text.push_str("\t}\n");
    if !out_rules.is_empty() {
        text.push_str(&format!(
            "\tchain {CHAIN_OUTPUT} {{\n\t\ttype route hook output priority {HOOK_PRIO}; policy accept;\n"
        ));
        for r in &out_rules {
            text.push_str(&format!("\t\t{r}\n"));
        }
        text.push_str("\t}\n");
    }
    text.push_str("}\n");

    let mut tags: Vec<Tag> = Vec::new();
    for t in [TAG_FOREIGN_CT, TAG_FOREIGN_PKT, TAG_NOT_NEW] {
        tags.push(Tag {
            comment: t.to_string(),
            chain: CHAIN_PREROUTING,
        });
    }
    if input.conn_sticky && caps.ct_mark_range {
        tags.push(Tag {
            comment: TAG_INHERIT.to_string(),
            chain: CHAIN_PREROUTING,
        });
    }
    if lan.is_empty() {
        tags.push(Tag {
            comment: TAG_NO_LAN.to_string(),
            chain: CHAIN_PREROUTING,
        });
    } else {
        tags.push(Tag {
            comment: TAG_NOT_LAN.to_string(),
            chain: CHAIN_PREROUTING,
        });
    }
    tags.extend(p.tags.iter().cloned());
    for b in &p.buckets {
        tags.push(Tag {
            comment: b.comment.clone(),
            chain: b.chain,
        });
    }
    if !out_rules.is_empty() {
        tags.push(Tag {
            comment: TAG_OUT_INHERIT.to_string(),
            chain: CHAIN_OUTPUT,
        });
    }
    p.tags = tags;
    p.issues = issues;
    p.text = text;
    p.summary = format!(
        "nft 程序：{} 条规则、{} 个集合、{} 条可热替换桶规则（桶 {} 个，算法 {}）",
        chain_rules.len() + out_rules.len(),
        p.sets.len(),
        p.buckets.len(),
        input.buckets,
        input.algorithm.as_str()
    );
    Ok(p)
}

/// 卸载/停用时的清理脚本：只删自己的表。
/// 清场程序：删掉本插表的表（停用 / 回滚到「从未安装」/ 关停回收都用它）。
///
/// 与 [`build`] 的主程序同一惯用法：先声明再删除，表不存在时也成功
/// （否则「清场一个本来就没装的设备」会报错，而清场失败比不装严重得多）。
pub fn teardown_program() -> String {
    format!("table inet {TABLE}\ndelete table inet {TABLE}\n")
}

/// 安装到 `/usr/share/nftables.d/ruleset-post/smartmwan.nft` 的静态占位文件
/// （fw4 自动片段目录，被 include 到 ruleset 顶层）。
///
/// 只声明表与空链，不含任何分类规则：设备重启后、守护进程起来之前，
/// 数据面处于「对象存在但没有规则」的中性状态，不会有残留的旧标记逻辑生效。
///
/// 真机实证（ImmortalWrt fw4-2025.03.17）：不能用 `/etc/nftables.d/`——该固件的
/// fw4 有一条内置 `include "/etc/nftables.d/*.nft"` 通配，落在 `table inet fw4`
/// **表体内部**，独立表片段放那里必然语法错误、fw4 整体拒绝加载。
pub fn include_file_text() -> String {
    let mut s = String::new();
    s.push_str(
        "# smartmwan 静态占位（由 luci-app-smartmwan 安装到 ruleset-post 自动片段目录）。\n",
    );
    s.push_str("# 这里只声明 table inet smw 与一条空的 prerouting 链；具体规则由 smartmwand 运行期写入。\n");
    s.push_str(
        "# output 链**不在这里声明**：它需要 `type route hook output`，该语法由守护进程在设备上\n",
    );
    s.push_str(
        "# 实测能力后再决定是否使用（见 probe_scripts / Capabilities::route_hook_output），\n",
    );
    s.push_str("# 占位文件必须只含确定可用的语法，否则 fw4 启动就会失败。\n");
    s.push_str("# 卸载本包即删除本文件；重启 fw4 后插件在内核里不再有任何对象。\n");
    s.push_str(&format!("table inet {TABLE} {{\n"));
    s.push_str(&format!(
        "\tchain {CHAIN_PREROUTING} {{\n\t\ttype filter hook prerouting priority {HOOK_PRIO}; policy accept;\n\t}}\n"
    ));
    s.push_str("}\n");
    s
}

/// 解析 `nft -a list chain ...` 输出。
///
/// 一条规则可能因为匿名集合过长而跨多行打印，因此按结尾的 `# handle N` 归并。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleInfo {
    pub handle: u64,
    pub comment: Option<String>,
    /// 去掉 handle 注释与 comment 后的规则体。
    pub body: String,
    pub packets: u64,
    pub bytes: u64,
}

pub fn parse_chain_listing(text: &str) -> Vec<RuleInfo> {
    let mut out = Vec::new();
    let mut buf = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty()
            || line.starts_with("chain ")
            || line.starts_with('#')
            || line.starts_with('{')
            || line == "}"
            || line.starts_with("type ")
            || line.starts_with("policy ")
        {
            continue;
        }
        if !buf.is_empty() {
            buf.push(' ');
        }
        buf.push_str(line);
        if let Some(h) = buf.rfind("# handle ") {
            let digits: String = buf[h + 9..]
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            let handle: u64 = digits.parse().unwrap_or(0);
            let (rule_txt, _) = buf.split_at(h);
            out.push(to_rule_info(handle, rule_txt.trim()));
            buf.clear();
        }
    }
    out
}

fn to_rule_info(handle: u64, rule_txt: &str) -> RuleInfo {
    let mut comment = None;
    if let Some(i) = rule_txt.find("comment \"") {
        let rest = &rule_txt[i + 9..];
        if let Some(j) = rest.find('"') {
            comment = Some(rest[..j].to_string());
        }
    }
    let mut packets = 0u64;
    let mut bytes = 0u64;
    if let Some(i) = rule_txt.find("packets ") {
        let rest = &rule_txt[i + 8..];
        packets = take_u64(rest);
        if let Some(j) = rest.find("bytes ") {
            bytes = take_u64(&rest[j + 6..]);
        }
    }
    // 规则体：去掉 counter 计数与 comment，留下可比较的语义部分。
    let mut body = rule_txt.to_string();
    if let Some(i) = body.find("comment \"") {
        let end = body[i + 9..]
            .find('"')
            .map(|j| i + 9 + j + 1)
            .unwrap_or(body.len());
        body.replace_range(i..end, "");
    }
    if let Some(i) = body.find("packets ") {
        let end = body[i..]
            .find("bytes ")
            .map(|j| {
                let after = &body[i + j + 6..];
                let digits = after.chars().take_while(|c| c.is_ascii_digit()).count();
                i + j + 6 + digits
            })
            .unwrap_or(body.len());
        body.replace_range(i..end, "");
    }
    body = body.split_whitespace().collect::<Vec<_>>().join(" ");
    RuleInfo {
        handle,
        comment,
        body,
        packets,
        bytes,
    }
}

fn take_u64(s: &str) -> u64 {
    s.chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .unwrap_or(0)
}

/// 临时脚本文件：写 0600，`Drop` 里删除，保证不在设备上留下含规则的残片。
struct Script {
    path: PathBuf,
}

impl Script {
    fn write(dir: &Path, text: &str) -> Result<Script> {
        static SEQ: AtomicU32 = AtomicU32::new(1);
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let path = dir.join(format!("smw-{}-{n}.nft", std::process::id()));
        std::fs::write(&path, text)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }
        Ok(Script { path })
    }
}

impl Drop for Script {
    fn drop(&mut self) {
        if let Err(e) = std::fs::remove_file(&self.path) {
            if e.kind() != std::io::ErrorKind::NotFound {
                logging::warn_ctx(
                    "firewall",
                    "tmp-cleanup",
                    &format!("临时 nft 脚本未删除: {e}"),
                    &[("path", self.path.display().to_string())],
                );
            }
        }
    }
}

/// `nft` 执行器。程序路径可注入，便于在无 root、无 nft 的环境里测试错误路径。
#[derive(Debug, Clone)]
pub struct Nft {
    program: String,
    tmp_dir: PathBuf,
    timeout: Duration,
}

impl Nft {
    pub fn new(tmp_dir: impl AsRef<Path>) -> Result<Nft> {
        let program = exec::nft_program().ok_or_else(|| {
            logging::error_ctx(
                "firewall",
                "detect",
                Error::Firewall("设备上找不到 nft 可执行文件（/usr/sbin/nft 或 /sbin/nft）".into()),
                &[],
            )
        })?;
        Ok(Nft {
            program,
            tmp_dir: tmp_dir.as_ref().to_path_buf(),
            timeout: Duration::from_millis(exec::DEFAULT_TIMEOUT_MS),
        })
    }

    /// 显式注入程序（测试用：`/bin/true`、`/bin/false` 模拟成功与失败）。
    pub fn with_program(program: impl Into<String>, tmp_dir: impl AsRef<Path>) -> Nft {
        Nft {
            program: program.into(),
            tmp_dir: tmp_dir.as_ref().to_path_buf(),
            timeout: Duration::from_millis(3000),
        }
    }

    pub fn program(&self) -> &str {
        &self.program
    }

    pub fn set_timeout(&mut self, t: Duration) {
        self.timeout = t;
    }

    async fn run(&self, inv: &Invocation) -> Result<exec::Outcome> {
        exec::run_ok(inv).await
    }

    /// 校验（`nft -c -f`）：只解析与语义检查，不提交任何变更。
    pub async fn check(&self, text: &str) -> Result<()> {
        let s = Script::write(&self.tmp_dir, text)?;
        let inv = Invocation::nft_file(&self.program, &s.path, true, self.timeout)?;
        match exec::run(&inv).await {
            Ok(o) if o.ok() => Ok(()),
            Ok(o) => Err(logging::error_ctx(
                "firewall",
                "check",
                Error::Firewall(format!(
                    "nft 校验失败（退出码 {}）：{}",
                    o.status,
                    first_error_line(&o.stderr, &o.stdout)
                )),
                &[("label", o.label)],
            )),
            Err(e) => Err(e),
        }
    }

    /// 原子提交（`nft -f`）。
    pub async fn apply(&self, text: &str) -> Result<()> {
        let s = Script::write(&self.tmp_dir, text)?;
        let inv = Invocation::nft_file(&self.program, &s.path, false, self.timeout)?;
        match exec::run(&inv).await {
            Ok(o) if o.ok() => Ok(()),
            Ok(o) => Err(logging::error_ctx(
                "firewall",
                "apply",
                Error::Firewall(format!(
                    "nft 提交失败（退出码 {}）：{}",
                    o.status,
                    first_error_line(&o.stderr, &o.stdout)
                )),
                &[("label", o.label)],
            )),
            Err(e) => Err(e),
        }
    }

    /// 列出某条链（带 handle），用于应用后校验与热替换定位。
    pub async fn list_chain(&self, chain: &str) -> Result<Vec<RuleInfo>> {
        let chain = safe_name("链名", chain, 40)?;
        let inv = Invocation::with_options(
            &self.program,
            &["-a", "list", "chain", "inet", TABLE, &chain],
            self.timeout,
            128 * 1024,
            "nft-list",
        )?;
        let o = self.run(&inv).await?;
        Ok(parse_chain_listing(&o.stdout))
    }

    /// 按 handle 替换单条规则（热路径：桶重排）。
    pub async fn replace_rule(&self, chain: &str, handle: u64, body: &str) -> Result<()> {
        let chain = safe_name("链名", chain, 40)?;
        if handle == 0 {
            return Err(Error::Config("规则 handle 为 0，无法定位".into()));
        }
        if body.is_empty() || body.contains('\n') {
            return Err(Error::Config("规则体非法（空或含换行）".into()));
        }
        let h = handle.to_string();
        let inv = Invocation::with_options(
            &self.program,
            &["replace", "rule", "inet", TABLE, &chain, "handle", &h, body],
            self.timeout,
            8192,
            "nft-replace",
        )?;
        match exec::run(&inv).await {
            Ok(o) if o.ok() => Ok(()),
            Ok(o) => Err(logging::error_ctx(
                "firewall",
                "replace-rule",
                Error::Firewall(format!(
                    "替换 handle {handle} 失败：{}",
                    first_error_line(&o.stderr, &o.stdout)
                )),
                &[("chain", chain), ("handle", h)],
            )),
            Err(e) => Err(e),
        }
    }

    /// 读取版本（诊断用）。**取不到一律返回 `None`**，绝不返回空串冒充「版本为空」。
    ///
    /// 失败不阻断主流程（版本号只是诊断信息），但每一种失败都要留下一条日志，
    /// 否则真机上「nft 装了但 --version 报错」会被显示成「没装 nft」。
    pub async fn version(&self) -> Option<String> {
        let inv = match Invocation::with_options(
            &self.program,
            &["--version"],
            self.timeout,
            4096,
            "nft-version",
        ) {
            Ok(i) => i,
            Err(e) => {
                logging::warn_ctx(
                    "firewall",
                    "version",
                    &format!("无法构造 nft --version 调用：{e}"),
                    &[],
                );
                return None;
            }
        };
        let o = match exec::run(&inv).await {
            Ok(o) => o,
            Err(e) => {
                logging::warn_ctx(
                    "firewall",
                    "version",
                    &format!("nft --version 执行失败：{e}"),
                    &[],
                );
                return None;
            }
        };
        if !o.ok() {
            logging::warn_ctx(
                "firewall",
                "version",
                &format!(
                    "nft --version 退出码 {}：{}",
                    o.status,
                    first_error_line(&o.stderr, &o.stdout)
                ),
                &[],
            );
            return None;
        }
        let pick = |s: &str| s.trim().lines().next().unwrap_or("").trim().to_string();
        // 有些 nft 构建把版本信息写到 stderr，两边都要看；都空才算取不到。
        let text = {
            let t = pick(&o.stdout);
            if t.is_empty() {
                pick(&o.stderr)
            } else {
                t
            }
        };
        if text.is_empty() {
            logging::warn_ctx(
                "firewall",
                "version",
                "nft --version 退出 0 但没有输出，按「版本未知」处理",
                &[],
            );
            return None;
        }
        Some(text)
    }

    /// 添加动态集合元素（域名解析结果）。已存在的元素由 nft 报 EEXIST，视为成功。
    pub async fn add_elements(&self, set: &str, elems: &[String], timeout_s: u64) -> Result<usize> {
        let set = safe_name("集合名", set, 60)?;
        if elems.is_empty() {
            return Ok(0);
        }
        if elems.len() > MAX_SET_ELEMENTS {
            return Err(Error::Config(format!(
                "单次写入元素 {} 超上限",
                elems.len()
            )));
        }
        let mut clean: Vec<String> = Vec::with_capacity(elems.len());
        for e in elems {
            let e = e.trim();
            let ok = e
                .parse::<std::net::IpAddr>()
                .map(|a| {
                    matches!(a, std::net::IpAddr::V4(_)) || matches!(a, std::net::IpAddr::V6(_))
                })
                .unwrap_or(false);
            if !ok {
                return Err(Error::Config(format!("集合元素不是 IP 字面量：{e}")));
            }
            clean.push(e.to_string());
        }
        let body = if timeout_s > 0 {
            clean
                .iter()
                .map(|e| format!("{e} timeout {timeout_s}s"))
                .collect::<Vec<_>>()
                .join(", ")
        } else {
            clean.join(", ")
        };
        let stmt = format!("add element inet {TABLE} {set} {{ {body} }}\n");
        self.apply(&stmt).await?;
        Ok(clean.len())
    }

    /// 删除集合元素（只删自己集合里的元素）。
    pub async fn del_elements(&self, set: &str, elems: &[String]) -> Result<()> {
        let set = safe_name("集合名", set, 60)?;
        if elems.is_empty() {
            return Ok(());
        }
        let mut clean = Vec::new();
        for e in elems {
            if e.parse::<std::net::IpAddr>().is_err() {
                return Err(Error::Config(format!("集合元素不是 IP 字面量：{e}")));
            }
            clean.push(e.trim().to_string());
        }
        let stmt = format!(
            "delete element inet {TABLE} {set} {{ {} }}\n",
            clean.join(", ")
        );
        self.apply(&stmt).await
    }

    /// 清空自己的集合。只接受本模块生成的集合名（`smw` 前缀）。
    pub async fn flush_set(&self, set: &str) -> Result<()> {
        let set = safe_name("集合名", set, 60)?;
        if !set.starts_with("smw") {
            return Err(Error::Permission(format!("拒绝清空非本插件集合：{set}")));
        }
        self.apply(&format!("flush set inet {TABLE} {set}\n")).await
    }
}

/// nft 的错误常在第一/二行，保留全部文本又会撑爆日志，这里取有效信息。
fn first_error_line(stderr: &str, stdout: &str) -> String {
    let src = if stderr.trim().is_empty() {
        stdout
    } else {
        stderr
    };
    let lines: Vec<&str> = src
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();
    let mut out = lines
        .iter()
        .take(3)
        .cloned()
        .collect::<Vec<_>>()
        .join(" | ");
    if out.len() > 400 {
        out.truncate(400);
    }
    if out.is_empty() {
        out = "（nft 未输出错误信息）".to_string();
    }
    out
}

/// 应用后校验：把期望标签与实际链内容比对。
#[derive(Debug, Clone, Default)]
pub struct VerifyReport {
    pub missing: Vec<String>,
    pub unexpected: Vec<String>,
    pub rules: Vec<RuleInfo>,
}

impl VerifyReport {
    pub fn ok(&self) -> bool {
        self.missing.is_empty() && self.unexpected.is_empty()
    }
    pub fn describe(&self) -> String {
        if self.ok() {
            return "nft 校验通过".to_string();
        }
        format!(
            "缺失标签 [{}]；多余标签 [{}]",
            self.missing.join(", "),
            self.unexpected.join(", ")
        )
    }
}

/// 校验实际规则是否覆盖期望标签。
///
/// 判定基准是 `comment`：本程序生成的每条规则都带 `smw:` 前缀的 comment，
/// 设备上其它来源的规则（若有）不带，因此只比较 `smw:` 前缀集合，避免误报。
pub fn verify(expected: &[Tag], actual: &[RuleInfo]) -> VerifyReport {
    let mut rep = VerifyReport {
        rules: actual.to_vec(),
        ..Default::default()
    };
    let have: Vec<String> = actual
        .iter()
        .filter_map(|r| r.comment.clone())
        .filter(|c| c.starts_with("smw:"))
        .collect();
    for e in expected {
        if !have.contains(&e.comment) {
            rep.missing.push(e.comment.clone());
        }
    }
    for h in &have {
        if !expected.iter().any(|e| &e.comment == h) {
            rep.unexpected.push(h.clone());
        }
    }
    rep
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::system::netlink::Family;

    /// 真机集成探测：设备上有 `nft` 且当前用户能跑 `nft -c` 时，
    /// 把每条探测脚本的真实结果打印出来（`cargo test -- --nocapture` 看）。
    ///
    /// 它存在的理由是一次真实的排错：`nft -c <文件>`（缺 `-f`）会把路径当成命令
    /// 解析，导致**每一条**探测都失败，而手动 `nft -c -f` 同样内容却通过 ——
    /// 没有这条测试，这类「exec 通道与手敲命令不一致」的问题只能到真机部署后才暴露。
    /// 没有 nft 或没有权限时安静跳过（不是失败）。
    #[tokio::test]
    async fn real_nft_probe_reports_each_script() {
        if crate::system::exec::nft_program().is_none() {
            eprintln!("[skip] 没有 nft 可执行文件");
            return;
        }
        let dir = tempfile::TempDir::new().unwrap();
        let Ok(nft) = Nft::new(dir.path()) else {
            eprintln!("[skip] 构造 Nft 失败");
            return;
        };
        for (key, script, desc) in probe_scripts() {
            match nft.check(&script).await {
                Ok(()) => println!("[probe ok]   {key} — {desc}"),
                Err(e) => println!("[probe fail] {key} — {desc} — {e}"),
            }
        }
        let caps = probe_caps(&nft).await;
        println!("[probe caps] version={} {:?}", caps.version, caps);
    }

    fn line(name: &str, slot: u8) -> Line {
        Line {
            name: name.into(),
            slot,
        }
    }

    fn map_all(slots: &[u8], buckets: u16) -> Vec<u8> {
        let mut v = Vec::with_capacity(buckets as usize);
        for b in 0..buckets {
            v.push(slots[(b as usize) % slots.len()]);
        }
        v
    }

    /// 默认能力表（进程内单例），让测试夹具能返回带 `'static` 生命周期的引用。
    fn default_caps() -> &'static Capabilities {
        static C: std::sync::OnceLock<Capabilities> = std::sync::OnceLock::new();
        C.get_or_init(Capabilities::default)
    }

    fn input<'a>(lines: &'a [Line], bucket_map: &'a [u8], lan: &'a [String]) -> Input<'a> {
        Input {
            algorithm: Algorithm::SrcIpDstIp,
            buckets: bucket_map.len() as u16,
            bucket_map,
            gen: 1,
            hash_seed: 0,
            conn_sticky: true,
            families: &[Family::V4],
            lan_ifaces: lan,
            lines,
            games: &[],
            protected_v4: &[],
            protected_v6: &[],
            bypass_v4: &[],
            bypass_v6: &[],
            caps: default_caps(),
        }
    }

    #[test]
    fn safe_name_rejects_injection_shapes() {
        // 这些都必须被拒，而不是「加引号后放过」。
        for bad in [
            "a b", "a\"b", "a\\b", "a\nb", "-lead", "", "a;drop", "a$b", "a`b`",
        ] {
            assert!(safe_name("规则", bad, 40).is_err(), "{bad:?} 必须被拒绝");
        }
        assert_eq!(safe_name("规则", "pubg_eu", 40).unwrap(), "pubg_eu");
        assert_eq!(safe_name("规则", "a-b.c_1", 40).unwrap(), "a-b.c_1");
        assert!(safe_quoted("接口", "br\"lan").is_err());
        assert!(safe_quoted("接口", "br\nlan").is_err());
        assert_eq!(safe_quoted("接口", "br-lan").unwrap(), "br-lan");
    }

    #[test]
    fn build_produces_ownership_and_coexistence_rules() {
        let lines = vec![line("wan", 1), line("wan2", 2)];
        let map = map_all(&[1, 2], 8);
        let lan = vec!["br-lan".to_string()];
        let p = build(&input(&lines, &map, &lan)).unwrap();
        assert!(p.text.contains(&format!("delete table inet {TABLE}")));
        assert!(p.text.contains("table inet smw {"));
        // 继承自己的、不介入别人的、非 LAN 不动、老连接不动。
        for tag in [
            TAG_INHERIT,
            TAG_FOREIGN_CT,
            TAG_FOREIGN_PKT,
            TAG_NOT_LAN,
            TAG_NOT_NEW,
        ] {
            assert!(p.text.contains(tag), "缺少规则 {tag}：\n{}", p.text);
        }
        assert!(p.text.contains(marks::own_range_text()));
        assert!(!p.text.contains("flush"), "绝不能出现 flush 他人对象的语句");
        assert!(p.text.contains("iifname != { \"br-lan\" }"));
        assert!(p.summary.contains("算法 src_ip_dst_ip"), "{}", p.summary);
    }

    #[test]
    fn build_never_touches_other_tables() {
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let p = build(&input(&lines, &map, &lan)).unwrap();
        // 唯一被 delete 的对象是自己的表。
        let deletes: Vec<&str> = p
            .text
            .lines()
            .filter(|l| l.trim_start().starts_with("delete "))
            .collect();
        assert_eq!(deletes, vec![format!("delete table inet {TABLE}")]);
        assert!(!p.text.contains("inet fw4"), "程序里绝不能出现 fw4");
    }

    #[test]
    fn missing_lan_devices_disables_classification() {
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let p = build(&input(&lines, &map, &[])).unwrap();
        assert!(p.text.contains(TAG_NO_LAN));
        assert!(p.buckets.is_empty(), "没有 LAN 设备时不装桶规则");
        assert!(p.issues.iter().any(|i| i.message.contains("LAN 接口")));
        // 「不分类」= 不加标记规则，绝不是 drop：prerouting 里的 drop 会断掉
        // 包括管理面在内的全部流量（真机集成测试里 WSL 网络被这条规则打通过）。
        let no_lan_line = p
            .text
            .lines()
            .find(|l| l.contains(TAG_NO_LAN))
            .expect("必须留下 no-lan 标签");
        assert!(
            no_lan_line.trim_start().starts_with("counter"),
            "no-lan 规则只能是 counter，实际: {no_lan_line}"
        );
        // 且必须仍然是合法批次（不含未闭合的花括号）
        assert!(p.text.trim_end().ends_with('}'));
    }

    #[test]
    fn bucket_mark_layout_matches_contract() {
        let lines = vec![line("wan", 1), line("wan2", 2)];
        let map = map_all(&[1, 2], 4);
        let lan = vec!["br-lan".to_string()];
        let mut inp = input(&lines, &map, &lan);
        inp.gen = 3;
        let p = build(&inp).unwrap();
        assert_eq!(p.buckets.len(), 1, "IPv4 单族一条桶规则");
        let body = &p.buckets[0].body;
        // 标记必须带魔数，且槽位在低 8 位；bucket 在 bit16..23、gen 在 bit12..15。
        let m3 = marks::mark(2, marks::CLASS_NORMAL, 3, 3);
        assert!(body.contains(&marks::hex(m3).to_string()), "{body}");
        assert!(body.contains("mod 4 map"));
        assert_eq!(p.buckets[0].comment, "smw:bucket:v4");
        assert!(body.starts_with("meta mark == 0 ct state new"));
    }

    #[test]
    fn bucket_zero_means_no_marking() {
        // 槽位 0 = 该桶不分流（维护中线路、未启用的备份线路用）。
        let lines = vec![line("wan", 1)];
        let map = vec![0, 0, 1, 1];
        let lan = vec!["br-lan".to_string()];
        let p = build(&input(&lines, &map, &lan)).unwrap();
        assert!(
            p.buckets[0].body.contains("0 : 0x00000000"),
            "{}",
            p.buckets[0].body
        );
        assert!(!p.text.contains("drop comment \"smw:no-lan"));
    }

    #[test]
    fn port_algorithms_emit_transport_dependency() {
        let lines = vec![line("wan", 1), line("wan2", 2)];
        let map = map_all(&[1, 2], 4);
        let lan = vec!["br-lan".to_string()];
        let mut inp = input(&lines, &map, &lan);
        inp.algorithm = Algorithm::FullFiveTuple;
        let p = build(&inp).unwrap();
        let b = &p.buckets[0];
        assert!(b.body.contains("meta l4proto { tcp, udp }"), "{}", b.body);
        assert!(b.body.contains("th sport"));
        assert!(b.body.contains("th dport"));
        assert!(
            b.body.contains("ip protocol ."),
            "IPv4 五元组应含 ip protocol"
        );
    }

    #[test]
    fn port_algorithms_degrade_without_th_payload() {
        let lines = vec![line("wan", 1), line("wan2", 2)];
        let map = map_all(&[1, 2], 4);
        let lan = vec!["br-lan".to_string()];
        let caps = Capabilities {
            th_payload: false,
            ..Default::default()
        };
        let mut inp = input(&lines, &map, &lan);
        inp.algorithm = Algorithm::SrcIpDstIpDstPort;
        inp.caps = &caps;
        let p = build(&inp).unwrap();
        // 不支持 th 时退回无端口哈希：规则仍要装，否则完全不分流。
        assert_eq!(p.buckets.len(), 1);
        assert!(!p.buckets[0].body.contains("th dport"));
        assert!(
            p.issues.iter().any(|i| i.message.contains("不支持")),
            "{:?}",
            p.issues
        );
    }

    #[test]
    fn weighted_ecmp_is_reported_unimplemented_not_silently_wrong() {
        let lines = vec![line("wan", 1), line("wan2", 2)];
        let map = map_all(&[1, 2], 4);
        let lan = vec!["br-lan".to_string()];
        let mut inp = input(&lines, &map, &lan);
        inp.algorithm = Algorithm::WeightedEcmp;
        let p = build(&inp).unwrap();
        assert!(p.buckets.is_empty(), "ECMP 不通过 nft 桶实现");
        assert!(
            p.issues.iter().any(|i| i.message.contains("尚未实现")),
            "必须如实说明未实现: {:?}",
            p.issues
        );
    }

    #[test]
    fn without_ct_mark_range_no_classification_is_installed() {
        // 没有区间匹配 → 无法判断「这个 ct mark 是不是我的」，因此不写继承规则；
        // 分类规则仍然安装（外来标记由 `ct mark != 0 accept` 挡住），
        // 但必须明确告诉用户「已建连接的出口保持」这一条已经不成立了。
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let caps = Capabilities {
            ct_mark_range: false,
            ..Default::default()
        };
        let mut inp = input(&lines, &map, &lan);
        inp.caps = &caps;
        let p = build(&inp).unwrap();
        assert!(!p.text.contains(TAG_INHERIT), "不能写无法验证的继承规则");
        assert!(!p.text.contains(marks::own_range_text()));
        assert_eq!(p.buckets.len(), 1, "分类规则照常安装，流量仍被均衡");
        assert!(
            p.issues
                .iter()
                .any(|i| i.message.contains("区间匹配") && i.severity == Severity::Warning),
            "{:?}",
            p.issues
        );
    }

    #[test]
    fn game_rules_use_named_sets_and_mark_class_game() {
        let lines = vec![line("wan", 1), line("wan2", 2)];
        let map = map_all(&[1, 2], 4);
        let lan = vec!["br-lan".to_string()];
        let g = GameSpec {
            name: "PUBG EU".into(),
            slug: "pubg_eu".into(),
            priority: 10,
            mark: marks::mark(2, marks::CLASS_GAME, 1, 0),
            v4: vec!["158.101.0.0/16".into()],
            v6: vec![],
            macs: vec!["AA:BB:CC:DD:EE:FF".into()],
            client_v4: vec!["192.168.1.20".into()],
            client_v6: vec![],
            ports: vec!["30000-30100".into()],
            proto: ProtoFilter::Udp,
            dns_set: None,
            dns_timeout_s: 120,
        };
        let mmark = g.mark;
        let games = [g];
        let mut inp = input(&lines, &map, &lan);
        inp.games = &games;
        let p = build(&inp).unwrap();
        assert!(p.text.contains("set smw_g_pubg_eu_dst4"), "{}", p.text);
        assert!(p.text.contains("set smw_g_pubg_eu_mac"));
        assert!(p.text.contains("aa:bb:cc:dd:ee:ff"), "MAC 统一小写");
        assert!(p.text.contains("158.101.0.0/16"));
        assert!(p.text.contains("192.168.1.20/32"), "主机地址补 /32");
        let rule = p
            .text
            .lines()
            .find(|l| l.contains("smw:game:pubg_eu"))
            .unwrap()
            .to_string();
        assert!(rule.contains("meta l4proto udp"));
        assert!(rule.contains("th dport { 30000-30100 }"));
        // 回归：MAC 与客户端 IP 条件必须真的出现在规则文本里。
        // 曾经的缺陷是匹配项拼接时按 `@` 前缀过滤，把裸集合引用（MAC）整条丢掉，
        // 集合仍然被声明（所以旧断言能过），但规则不再限制主机 —— 静默放宽匹配范围。
        assert!(
            rule.contains("ether saddr @smw_g_pubg_eu_mac"),
            "MAC 条件必须出现在规则里：{rule}"
        );
        assert!(
            rule.contains("ip saddr @smw_g_pubg_eu_cli4"),
            "客户端 IP 条件必须出现在规则里：{rule}"
        );
        assert!(rule.contains("ip daddr @smw_g_pubg_eu_dst4"));
        assert!(rule.contains("counter"));
        assert!(rule.contains(&marks::hex(mmark).to_string()));
        assert!(rule.contains("ct mark set meta mark"));
        assert!(p.sets.iter().any(|s| s == "smw_g_pubg_eu_dst4"));
    }

    #[test]
    fn dns_set_requires_capability() {
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let g = GameSpec {
            name: "svc".into(),
            slug: "svc".into(),
            priority: 20,
            mark: marks::mark(1, marks::CLASS_GAME, 0, 0),
            v4: vec![],
            v6: vec![],
            macs: vec![],
            client_v4: vec![],
            client_v6: vec![],
            ports: vec![],
            proto: ProtoFilter::Both,
            dns_set: Some("smw_g_svc_dns".into()),
            dns_timeout_s: 90,
        };
        let caps_on = Capabilities {
            dyn_timeout_sets: true,
            ..Default::default()
        };
        let games = [g];
        let mut inp = input(&lines, &map, &lan);
        inp.games = &games;
        inp.caps = &caps_on;
        let p = build(&inp).unwrap();
        assert!(p.text.contains("flags dynamic,timeout"));
        assert!(p.text.contains("size 1024"));
        assert!(p.text.contains("timeout 90s"));
        assert!(p.text.contains("ip daddr @smw_g_svc_dns"));

        // 设备不支持动态集合时：规则整体降级，但必须留下明确说明。
        let caps_off = Capabilities {
            dyn_timeout_sets: false,
            ..Default::default()
        };
        let mut inp2 = input(&lines, &map, &lan);
        inp2.games = &games;
        inp2.caps = &caps_off;
        let p2 = build(&inp2).unwrap();
        assert!(!p2.text.contains("dynamic"), "不应写出未验证语法");
        assert!(
            p2.issues.iter().any(|i| i.message.contains("dynamic")),
            "{:?}",
            p2.issues
        );
        // 关键安全断言：域名条件不支持时**一条规则都不下**。
        // 旧写法是 `if v4_dst 非空 … else if dns_set … else 兜底`，
        // 于是「v4_dst 空 + dns_set 有但不支持」会走到声明集合那支的 else（只报警），
        // 而「v4_dst 空 + dns_set 无」才该走兜底；重构后若把这两种情况混在一起，
        // 就会产出一条只带客户端条件、命中这批主机全部新建连接的宽规则。
        assert!(
            !p2.text.contains("smw:game:svc"),
            "不支持域名条件时不能退化成兜底规则：\n{}",
            p2.text
        );
        assert!(p2.tags.iter().all(|t| !t.comment.contains("smw:game:svc")));
    }

    #[test]
    fn mac_only_rule_is_not_emitted_when_ether_sets_unsupported() {
        // 与前两条同类的第三处「静默放宽」：规则用 MAC 限定主机，而设备 nft 不支持
        // ether_addr 集合时，原先只是丢掉一个匹配项 —— 结果规则变成
        // 「全 LAN 的新建连接命中该目的网段」，范围反而被放大了。
        // 正确做法是整条不下发（规则不生效），并给出可显示的原因。
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let g = GameSpec {
            name: "mac only".into(),
            slug: "maconly".into(),
            priority: 20,
            mark: marks::mark(1, marks::CLASS_GAME, 0, 0),
            v4: vec!["203.0.113.0/24".into()],
            v6: vec![],
            macs: vec!["aa:bb:cc:dd:ee:ff".into()],
            client_v4: vec![],
            client_v6: vec![],
            ports: vec![],
            proto: ProtoFilter::Both,
            dns_set: None,
            dns_timeout_s: 90,
        };
        let games = [g];

        // 支持 ether 集合：MAC 条件必须在文本里。
        let mut inp = input(&lines, &map, &lan);
        inp.games = &games;
        let p = build(&inp).unwrap();
        assert!(
            p.text.contains("ether saddr @smw_g_maconly_mac"),
            "支持时 MAC 条件必须生效：\n{}",
            p.text
        );

        // 不支持：整条规则消失，且必须留下说明。
        let caps_off = Capabilities {
            ether_sets: false,
            ..Default::default()
        };
        let mut inp2 = input(&lines, &map, &lan);
        inp2.games = &games;
        inp2.caps = &caps_off;
        let p2 = build(&inp2).unwrap();
        assert!(
            !p2.text.contains("smw:game:maconly"),
            "客户端条件全灭时不能退化成放宽规则：\n{}",
            p2.text
        );
        assert!(p2
            .tags
            .iter()
            .all(|t| !t.comment.contains("smw:game:maconly")));
        assert!(
            p2.issues
                .iter()
                .any(|i| i.message.contains("客户端条件全部无法生效")),
            "必须给出可显示的原因：{:?}",
            p2.issues
        );
        // 集合也不能被声明（否则留下无人引用的对象，清理时会误判所有权）。
        assert!(!p2.text.contains("set smw_g_maconly_mac"));
    }

    #[test]
    fn cidr_and_dns_conditions_each_get_a_rule() {
        // 固定网段与域名是「或」关系：两类目的条件必须各出一条规则。
        // 旧实现写成 if/else if 链，只要有固定网段就永远不会声明 DNS 集合，
        // 域名条件被静默丢掉，且没有任何降级说明。
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let g = GameSpec {
            name: "mixed".into(),
            slug: "mixed".into(),
            priority: 20,
            mark: marks::mark(1, marks::CLASS_GAME, 0, 0),
            v4: vec!["203.0.113.0/24".into()],
            v6: vec![],
            macs: vec![],
            client_v4: vec![],
            client_v6: vec![],
            ports: vec![],
            proto: ProtoFilter::Both,
            dns_set: Some("smw_g_mixed_dns".into()),
            dns_timeout_s: 300,
        };
        let caps_on = Capabilities {
            dyn_timeout_sets: true,
            ..Default::default()
        };
        let games = [g];
        let mut inp = input(&lines, &map, &lan);
        inp.games = &games;
        inp.caps = &caps_on;
        let p = build(&inp).unwrap();
        assert!(p.text.contains("set smw_g_mixed_dst4"), "{}", p.text);
        assert!(p.text.contains("flags dynamic,timeout"));
        assert!(p.sets.iter().any(|s| s == "smw_g_mixed_dns"));
        let rules: Vec<&str> = p
            .text
            .lines()
            .filter(|l| l.contains("smw:game:mixed"))
            .collect();
        assert_eq!(rules.len(), 2, "两条目的条件应有两条规则：{rules:?}");
        assert!(rules
            .iter()
            .any(|r| r.contains("ip daddr @smw_g_mixed_dst4")));
        assert!(rules
            .iter()
            .any(|r| r.contains("ip daddr @smw_g_mixed_dns")));
        // 两条都必须真的带标记，否则第二条只是计数不看出口。
        for r in &rules {
            assert!(r.contains("meta mark set"), "{r}");
        }

        // 能力不支持时：固定网段那条仍然下发，域名那条不生成兜底，并给出说明。
        let caps_off = Capabilities {
            dyn_timeout_sets: false,
            ..Default::default()
        };
        let mut inp2 = input(&lines, &map, &lan);
        inp2.games = &games;
        inp2.caps = &caps_off;
        let p2 = build(&inp2).unwrap();
        let rules2: Vec<&str> = p2
            .text
            .lines()
            .filter(|l| l.contains("smw:game:mixed"))
            .collect();
        assert_eq!(rules2.len(), 1, "只保留固定网段那条：{rules2:?}");
        assert!(rules2[0].contains("ip daddr @smw_g_mixed_dst4"));
        assert!(p2
            .issues
            .iter()
            .any(|i| i.message.contains("域名条件无法生效")));
    }

    #[test]
    fn invalid_inputs_are_rejected_before_writing_text() {
        let lines = vec![line("wan", 1)];
        let lan = vec!["br-lan".to_string()];
        // 桶映射长度不符
        let short_map = vec![1u8, 1, 1];
        let mut inp = input(&lines, &short_map, &lan);
        inp.buckets = 8;
        assert!(build(&inp).is_err());
        // 槽位非法
        let bad = vec![Line {
            name: "x".into(),
            slot: 0,
        }];
        let zmap = vec![0u8, 0, 1, 1];
        let mut inp = input(&bad, &zmap, &lan);
        inp.lines = &bad;
        assert!(build(&inp).is_err(), "槽位 0 的线路必须拒绝");
        // 未知槽位
        let map2 = vec![7, 1, 1, 1];
        let inp = input(&lines, &map2, &lan);
        assert!(build(&inp).is_err());
        // 端口文本非法
        let g = GameSpec {
            name: "n".into(),
            slug: "x".into(),
            priority: 1,
            mark: marks::mark(1, 0, 0, 0),
            v4: vec![],
            v6: vec![],
            macs: vec![],
            client_v4: vec![],
            client_v6: vec![],
            ports: vec!["443; drop".into()],
            proto: ProtoFilter::Both,
            dns_set: None,
            dns_timeout_s: 0,
        };
        let games = [g];
        let full_map = map_all(&[1], 4);
        let mut inp = input(&lines, &full_map, &lan);
        inp.games = &games;
        assert!(build(&inp).is_err(), "端口文本必须硬校验");
    }

    #[test]
    fn ipv6_is_gated_by_families() {
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let caps = Capabilities {
            route_hook_output: true,
            ..Default::default()
        };
        let fams = [Family::V4];
        let p6 = vec!["fd00::/8".to_string()];
        let mut inp = input(&lines, &map, &lan);
        inp.families = &fams;
        inp.protected_v6 = &p6;
        inp.caps = &caps;
        let p = build(&inp).unwrap();
        assert!(
            !p.text.contains("smw_protected_v6"),
            "IPv6 关闭时不建 IPv6 集合"
        );
        assert_eq!(p.buckets.len(), 1);
        assert!(p.text.contains("type route hook output"));
        assert!(p.text.contains(TAG_OUT_INHERIT));
    }

    #[test]
    fn conn_sticky_off_documents_the_risk() {
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let mut inp = input(&lines, &map, &lan);
        inp.conn_sticky = false;
        let p = build(&inp).unwrap();
        assert!(!p.text.contains(TAG_INHERIT));
        assert!(p.issues.iter().any(|i| i.message.contains("conn_sticky")));
    }

    #[test]
    fn verify_detects_missing_and_extra_tags() {
        let lines = vec![line("wan", 1)];
        let map = map_all(&[1], 4);
        let lan = vec!["br-lan".to_string()];
        let p = build(&input(&lines, &map, &lan)).unwrap();
        // 完全一致：无缺失无多余
        let actual: Vec<RuleInfo> = p
            .tags
            .iter()
            .enumerate()
            .map(|(i, t)| RuleInfo {
                handle: 10 + i as u64,
                comment: Some(t.comment.clone()),
                body: "x".into(),
                packets: 0,
                bytes: 0,
            })
            .collect();
        assert!(verify(&p.tags, &actual).ok());

        // 少了一条继承规则
        let mut partial = actual.clone();
        partial.retain(|r| r.comment.as_deref() != Some(TAG_INHERIT));
        let rep = verify(&p.tags, &partial);
        assert!(!rep.ok());
        assert_eq!(rep.missing, vec![TAG_INHERIT]);
        assert!(rep.describe().contains("缺失"));

        // 多出一条非本插件规则：不应误报（没有 smw: 前缀）
        let mut with_foreign = actual.clone();
        with_foreign.push(RuleInfo {
            handle: 99,
            comment: None,
            body: "meta mark set 0x1".into(),
            packets: 5,
            bytes: 500,
        });
        assert!(
            verify(&p.tags, &with_foreign).ok(),
            "外部规则不能被算成异常"
        );

        // 多出一条带 smw: 前缀的历史规则 → 必须报出（残留规则检查）
        let mut stale = actual.clone();
        stale.push(RuleInfo {
            handle: 98,
            comment: Some("smw:bucket:v6".into()),
            body: "x".into(),
            packets: 0,
            bytes: 0,
        });
        let rep = verify(&p.tags, &stale);
        assert_eq!(rep.unexpected, vec!["smw:bucket:v6"]);
    }

    #[test]
    fn parser_handles_multiline_and_counters() {
        let listing = r#"chain inet smw prerouting {
	type filter hook prerouting priority -150; policy accept;
	ct mark 0x05000000-0x05ffffff meta mark set ct mark accept comment "smw:inherit" # handle 3
	meta mark == 0 ct state new meta mark set jhash ip saddr . ip daddr mod 8 map {
		0 : 0x05000001, 1 : 0x05000002, 2 : 0x05000001,
		3 : 0x05000002 } counter packets 1234 bytes 567890 comment "smw:bucket:v4" # handle 7
}"#;
        let rs = parse_chain_listing(listing);
        assert_eq!(rs.len(), 2, "{rs:?}");
        assert_eq!(rs[0].handle, 3);
        assert_eq!(rs[0].comment.as_deref(), Some(TAG_INHERIT));
        assert_eq!(rs[1].handle, 7);
        assert_eq!(rs[1].comment.as_deref(), Some("smw:bucket:v4"));
        assert_eq!(rs[1].packets, 1234);
        assert_eq!(rs[1].bytes, 567890);
        // 计数与 comment 已从规则体剔除，便于语义比较
        assert!(!rs[1].body.contains("packets"));
        assert!(!rs[1].body.contains("smw:bucket"));
        assert!(rs[1].body.contains("jhash"));
    }

    #[test]
    fn parser_is_empty_on_blank_or_error_output() {
        assert!(parse_chain_listing("").is_empty());
        assert!(
            parse_chain_listing("Error: could not process family. \"inet\" not found.\n")
                .is_empty()
        );
    }

    #[test]
    fn include_file_is_inert() {
        let s = include_file_text();
        // 占位文件只声明对象，不含任何分类/标记规则，重启后不留残规则。
        assert!(s.contains("table inet smw"));
        assert!(s.contains("chain prerouting"));
        assert!(!s.contains("jhash"));
        assert!(!s.contains("meta mark set"));
        assert!(!s.contains("flush"));
        // 关键：占位文件只能有一个 hook，且必须是确定可用的 prerouting。
        // 曾经在这里多写了一条名为 output 却挂 prerouting 的链 —— 那是重复注册同一个
        // hook，虽然语法合法但语义错误；而 `type route hook output` 未经设备实测，
        // 写进静态占位会让 fw4 在不支持的内核上直接启动失败。
        // 断言只看非注释行，否则说明文字里的词会被误当成规则内容。
        let body: String = s
            .lines()
            .filter(|l| !l.trim_start().starts_with('#'))
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(
            body.matches("hook prerouting").count(),
            1,
            "占位文件不得重复注册 hook"
        );
        assert!(
            !body.contains("type route"),
            "未经能力探测的 hook 类型不得进入静态占位"
        );
        assert!(!body.contains("chain output"));
    }

    #[test]
    fn teardown_only_deletes_own_table() {
        // 清场必须幂等：表不存在时也要成功（先声明再删的惯用法，见 build 组装处）。
        assert_eq!(
            teardown_program(),
            format!("table inet {TABLE}\ndelete table inet {TABLE}\n")
        );
    }

    #[test]
    fn probe_scripts_are_self_contained() {
        let scripts = probe_scripts();
        assert_eq!(scripts.len(), 8);
        for (key, text, desc) in &scripts {
            assert!(!text.is_empty(), "{key} 探测脚本为空");
            assert!(!desc.is_empty());
            assert!(
                text.contains("smwprobe"),
                "{key} 必须只在一次性表里探测，不能引用 inet smw"
            );
            assert!(
                !text.contains("flush") && !text.contains("delete table inet smw\n"),
                "{key} 探测脚本不得触碰现有对象"
            );
        }
    }

    #[test]
    fn capabilities_default_is_conservative() {
        let c = Capabilities::default();
        assert!(!c.nft_exists);
        assert!(!c.route_hook_output);
        assert!(!c.dyn_timeout_sets);
        assert!(
            !c.jhash_seed,
            "jhash 种子参数在多数版本上不存在，默认按不支持处理"
        );
        // 一个都没通过：分类能力整体视为不可用。
        assert!(!capabilities_from_probe("nft v1.1.7", &[]).jhash_map);
        assert!(!capabilities_from_probe("nft v1.1.7", &[]).ct_mark_range);
        // 只有 jhash、没有区间匹配 → 仍判为不能分类（所有权判定是前提）。
        let only_jhash: Vec<String> = vec!["jhash_map".into()];
        assert!(!capabilities_from_probe("nft v1.1.7", &only_jhash).jhash_map);
        let passed: Vec<String> = [
            "jhash_map",
            "ct_mark_range",
            "th_payload",
            "dyn_timeout_sets",
            "route_hook_output",
            "ether_sets",
            "comments",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let full = capabilities_from_probe("nft v1.1.7", &passed);
        assert!(full.nft_exists && full.dyn_timeout_sets && full.route_hook_output);
        assert!(!full.jhash_seed);
    }
    #[test]
    fn new_without_nft_binary_reports_clearly() {
        let dir = tempfile::TempDir::new().unwrap();
        match Nft::new(dir.path()) {
            // 沙箱无 nft：必须给明确错误；真机有 nft：必须成功。两种都不 panic。
            Ok(n) => assert!(n.program().contains("nft")),
            Err(e) => assert!(e.to_string().contains("nft"), "{e}"),
        }
    }

    /// 探测脚本的形状必须是合法 nft：花括号配平、以 `}` 收尾、没有裸 `{}` 行。
    ///
    /// `mk()` 曾经把收尾写成 `{{}}`（Rust 格式字符串里这是字面 `{}`），于是每条
    /// mk() 探测都以 `{}` 结束，`nft -c` 报 `unexpected '}'` —— 探测全失败，
    /// 真机上会退化成大面积假降级。沙箱的替身不执行真 nft，所以只有形状断言能拦住它。
    #[test]
    fn probe_scripts_are_shape_valid() {
        for (key, script, _desc) in probe_scripts() {
            let opens = script.matches('{').count();
            let closes = script.matches('}').count();
            assert_eq!(opens, closes, "{key} 花括号不配平：{script}");
            assert_eq!(
                script.trim_end().lines().last(),
                Some("}"),
                "{key} 必须以单独一行 }} 收尾：{script}"
            );
            assert!(
                !script.lines().any(|l| l.trim() == "{}"),
                "{key} 含裸 {{}} 行（格式字符串转义错误）：{script}"
            );
        }
    }

    /// 能力探测的**判定逻辑**两端：全通过 ⇒ 高风险语法可用；全失败 ⇒ 一律保守关闭。
    ///
    /// 沙箱里没有 `nft` 也没有 netfilter，所以注入 `/bin/true`（恒退出 0）与
    /// `/bin/false`（恒退出 1）。这两条测试证明的是「探测结果如何转成能力表」，
    /// **不证明本机语法可用** —— 后者只能在真机上由 `--capabilities` 得出。
    #[tokio::test]
    async fn probe_caps_enables_everything_when_checks_pass() {
        let dir = tempfile::TempDir::new().unwrap();
        let nft = Nft::with_program("/bin/true", dir.path());
        let caps = probe_caps(&nft).await;
        assert!(caps.nft_exists);
        // jhash_map 以 ct_mark_range 为前提，两者同时通过才为真。
        assert!(caps.ct_mark_range && caps.jhash_map);
        for (name, on) in [
            ("th_payload", caps.th_payload),
            ("dyn_timeout_sets", caps.dyn_timeout_sets),
            ("route_hook_output", caps.route_hook_output),
            ("ether_sets", caps.ether_sets),
            ("comments", caps.comments),
            ("jhash_seed", caps.jhash_seed),
        ] {
            assert!(on, "全部试算通过时 {name} 仍被关闭，说明键名对不上");
        }
    }

    #[tokio::test]
    async fn probe_caps_keeps_conservative_defaults_when_checks_fail() {
        let dir = tempfile::TempDir::new().unwrap();
        let nft = Nft::with_program("/bin/false", dir.path());
        let caps = probe_caps(&nft).await;
        // 「nft 在但语法未证实」与「nft 不在」是两件事：前者 nft_exists 仍为真，
        // 但所有可选语法一律关闭，程序会走降级路径并给出可见的 Warning。
        assert!(caps.nft_exists);
        assert!(!caps.ct_mark_range && !caps.jhash_map);
        assert!(!caps.comments, "comment 未证实就不能启用 handle 定位路径");
        assert!(!caps.dyn_timeout_sets && !caps.route_hook_output && !caps.jhash_seed);
        assert!(!caps.th_payload && !caps.ether_sets);
    }

    #[tokio::test]
    async fn version_only_reports_a_real_string() {
        let dir = tempfile::TempDir::new().unwrap();
        // 退出码非 0 ⇒ None。旧写法会把 `exec::run` 的成功（子进程跑完了）误当成
        // 「取到版本」，于是返回 Some("")，UI 上就成了「版本为空」这种无法解释的状态。
        assert!(
            Nft::with_program("/bin/false", dir.path())
                .version()
                .await
                .is_none(),
            "nft --version 失败时必须明确说取不到"
        );
        // 退出 0 且有输出 ⇒ 拿到文本（用 echo 注入，证明解析路径本身可用）。
        assert!(Nft::with_program("/bin/echo", dir.path())
            .version()
            .await
            .is_some());
    }
}
