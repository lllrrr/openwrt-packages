//! 预置项（preset）加载。
//!
//! # 为什么默认一个预置项都没有
//!
//! 任务书要求「可维护的游戏预置项」，同时明确 **绝不编造服务器 IP/端口**。
//! 这两条合起来的唯一诚实做法是：
//!
//! * 插件本体 **不内置任何** 游戏服务器地址、端口或域名；
//! * 预置项是 **数据文件**，由管理员自己放置、自己确认来源，插件只负责
//!   读取、校验、并到规则里；
//! * 加载时强制要求 `source` 字段非空 —— 没有来源的网段清单无法被任何人复核，
//!   放进数据面等于把陌生网段的流量绑到一条线路上。这条是 **错误**，不是警告。
//!
//! 换句话说：这里的代码是可以带假数据跑单测的（单测里用 RFC 5737 文档地址段），
//! 但发布物里没有、也不该有真实服务器清单。
//!
//! # 文件格式
//!
//! `/usr/share/smartmwan/presets/*.json`，每个文件一个数组或一个对象：
//!
//! ```json
//! {
//!   "presets": [
//!     {
//!       "id": "demo-game",
//!       "label": "示例（不是真实服务器）",
//!       "source": "由管理员于 2026-10-26 从官方公布网段清单核对抄录",
//!       "updated": "2026-10-26",
//!       "targets": ["203.0.113.0/24"],
//!       "ports": ["30000-30100"],
//!       "proto": "udp",
//!       "domains": []
//!     }
//!   ]
//! }
//! ```
//!
//! `targets`/`ports` 里的内容仍会走 `matchers` 与 `config::validate` 的完整校验，
//! 所以数据文件写错（逆序端口段、非法 CIDR）会在应用前变成明确错误。

use std::path::Path;

use serde::Deserialize;

use crate::config::schema::ProtoFilter;
use crate::rules::matchers::{self, Addrs};
use crate::{Error, Result};

/// 安装目录（只读数据目录，与 LuCI 资源目录同级）。
pub const PRESET_DIR: &str = "/usr/share/smartmwan/presets";

/// 单个预置项文件的体积上限。数据文件是人手写的清单，
/// 超过这个体积几乎一定是「被误当成了别的东西」或「有人往里塞大文件」。
const MAX_FILE_BYTES: u64 = 512 * 1024;

/// 单个预置项在内存中的形态。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preset {
    pub id: String,
    /// UI 显示名。
    pub label: String,
    /// 来源声明，**必须非空**。
    pub source: String,
    pub updated: String,
    pub targets: Vec<String>,
    pub ports: Vec<String>,
    pub proto: ProtoFilter,
    pub domains: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct Wrapper {
    #[serde(default)]
    presets: Vec<Raw>,
}

#[derive(Debug, Deserialize, Default)]
struct Raw {
    #[serde(default)]
    id: String,
    #[serde(default)]
    label: String,
    #[serde(default)]
    source: String,
    #[serde(default)]
    updated: String,
    #[serde(default)]
    targets: Vec<String>,
    #[serde(default)]
    ports: Vec<String>,
    #[serde(default)]
    proto: String,
    #[serde(default)]
    domains: Vec<String>,
    // 数据文件里多写的键（将来字段演进）不应导致整个插件读不了配置。
    #[serde(flatten)]
    _extra: std::collections::BTreeMap<String, serde_json::Value>,
}

/// 解析单个预置项文本（一个文件可以有多个）。
///
/// 支持三种写法，按尝试顺序：顶层数组 `[...]`、`{"presets": [...]}`、单个对象 `{...}`。
///
/// 拒绝条件都是「会让数据面行为不明」的：空 id、重复 id、缺来源、目标为空。
/// 空 `targets` 且空 `domains` 的预置项没有意义 —— 它会把「全部新建连接」
/// 标成游戏流量，这是最危险的误用，必须拒绝。
pub fn parse_text(text: &str, origin: &str) -> Result<Vec<Preset>> {
    // 三种写法依次尝试；都失败才报错，并把最后两次的解析错误一起带上，
    // 便于定位「到底是哪个字段写错了」。
    let raws: Vec<Raw> = match serde_json::from_str::<Vec<Raw>>(text) {
        Ok(v) => v,
        Err(e_arr) => {
            match serde_json::from_str::<Wrapper>(text) {
                Ok(w) if !w.presets.is_empty() => w.presets,
                Ok(_) => match serde_json::from_str::<Raw>(text) {
                    Ok(one) => vec![one],
                    Err(e_one) => {
                        return Err(Error::Config(format!(
                            "预置项文件 {origin} 不是合法 JSON（已按 数组 / {{\"presets\":[…]}} / 单对象 三种写法尝试）：\
                             数组:{e_arr}；单对象:{e_one}"
                        )))
                    }
                },
                Err(e_wrap) => {
                    return Err(Error::Config(format!(
                        "预置项文件 {origin} 不是合法 JSON（已按 数组 / {{\"presets\":[…]}} 两种写法尝试）：\
                         数组:{e_arr}；包装对象:{e_wrap}"
                    )))
                }
            }
        }
    };
    let mut out: Vec<Preset> = Vec::new();
    for r in raws {
        let p = Preset {
            id: r.id.trim().to_string(),
            label: r.label.trim().to_string(),
            source: r.source.trim().to_string(),
            updated: r.updated.trim().to_string(),
            targets: r.targets.iter().map(|s| s.trim().to_string()).collect(),
            ports: r.ports.iter().map(|s| s.trim().to_string()).collect(),
            proto: match r.proto.trim().to_ascii_lowercase().as_str() {
                "" | "both" | "tcp_udp" | "any" => ProtoFilter::Both,
                "tcp" => ProtoFilter::Tcp,
                "udp" => ProtoFilter::Udp,
                other => {
                    return Err(Error::Config(format!(
                        "预置项 {} 的 proto 不认识：{other}（只支持 tcp/udp/both）",
                        r.id
                    )))
                }
            },
            domains: r.domains.iter().map(|s| s.trim().to_string()).collect(),
        };
        validate(&p, origin)?;
        // 同一文件内的重复 id 立刻报错并带上文件名；跨文件的重复由 `load_dir` 汇总后查。
        if out.iter().any(|e: &Preset| e.id == p.id) {
            return Err(Error::Config(format!(
                "预置项 id 重复：{}（文件 {origin} 内部）",
                p.id
            )));
        }
        out.push(p);
    }
    Ok(out)
}

fn validate(p: &Preset, origin: &str) -> Result<()> {
    if p.id.is_empty() {
        return Err(Error::Config(format!("预置项缺少 id（文件 {origin}）")));
    }
    // id 会出现在 UI、审计文本与错误信息里，也可能被下游拿去做对象名，因此字符集与长度
    // 按最严的来。注意 nft 对象名实际取自**规则段名**的 slug（`compile()` 里 `slug_of(&rule.name)`），
    // 不是这个 id —— 别指望改预置项 id 能改集合名。
    if p.id.len() > 40
        || !p
            .id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
    {
        return Err(Error::Config(format!(
            "预置项 id 只能含字母数字 _ . - 且不超过 40 字符：{}",
            p.id
        )));
    }
    if p.source.is_empty() {
        return Err(Error::Config(format!(
            "预置项 {} 缺少 source：没有来源的网段清单无法复核，拒绝加载。",
            p.id
        )));
    }
    if p.targets.is_empty() && p.domains.is_empty() {
        return Err(Error::Config(format!(
            "预置项 {} 既无 targets 也无 domains：这等于「命中全部新建连接」，太危险",
            p.id
        )));
    }
    if p.targets.len() > crate::system::firewall::MAX_SET_ELEMENTS {
        return Err(Error::Config(format!(
            "预置项 {} 的 targets 超过 {} 条上限",
            p.id,
            crate::system::firewall::MAX_SET_ELEMENTS
        )));
    }
    // 现在就跑一遍 matchers 校验：数据文件里的错误必须在「加载」时暴露，
    // 而不是等到下发 nft 时才炸，那时用户已经看不到是哪个文件写错了。
    matchers::split_normalize(&p.targets, &format!("预置项 {} targets", p.id))?;
    matchers::normalize_ports(&p.ports)?;
    matchers::normalize_domains(&p.domains)?;
    Ok(())
}

/// 从目录加载全部预置项。目录不存在 → 空表（不是错误：插件刚装好就是这样）。
///
/// 单个文件损坏 → 整批报错。刻意不做「跳过坏文件」：跳过之后规则里引用了
/// 那个文件里的预置项，就会变成「引用了不存在的预置项」，用户看到的
/// 是一个看不懂的错误，而不是「某个文件 JSON 写错了」。
pub fn load_dir(dir: &Path) -> Result<Vec<Preset>> {
    let mut all: Vec<Preset> = Vec::new();
    let rd = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(all),
        Err(e) => return Err(io_err(format!("读取预置项目录 {}", dir.display()), e)),
    };
    let mut names: Vec<std::path::PathBuf> = Vec::new();
    for entry in rd {
        let path = io_ctx(format!("枚举预置项目录 {}", dir.display()), entry)?.path();
        // 只认普通 .json 文件：子目录（例如备份目录）留着自己去看，不在这里猜。
        if !path.is_file() || path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        // 先用元数据判大小，避免有人塞一个几百 MB 的文件把守护进程读进内存。
        let len = io_ctx(format!("stat {}", path.display()), std::fs::metadata(&path))?.len();
        if len > MAX_FILE_BYTES {
            return Err(Error::Config(format!(
                "预置项文件 {} 超过 {} 字节上限，拒绝解析",
                path.display(),
                MAX_FILE_BYTES
            )));
        }
        names.push(path);
    }
    // 文件名排序：目录枚举顺序在不同文件系统上不稳定，而 id 冲突报错的顺序必须可复现。
    names.sort();
    for path in names {
        let text = io_ctx(
            format!("读取 {}", path.display()),
            std::fs::read_to_string(&path),
        )?;
        all.extend(parse_text(&text, &path.display().to_string())?);
    }
    all.sort_by(|a, b| a.id.cmp(&b.id));
    // 跨文件也要查重复 id：两个文件各自合法，合起来却让规则引用到不确定的清单。
    // 排序后再查，重复的 id 一定相邻。
    for w in all.windows(2) {
        if w[0].id == w[1].id {
            return Err(Error::Config(format!(
                "预置项 id 重复：{}（来自不同文件，请删掉其中一个）",
                w[0].id
            )));
        }
    }
    Ok(all)
}

/// 给 IO 错误加上「在做什么」的上下文，同时保留原始 `ErrorKind`。
///
/// 保留 kind 是有意的：调用方要靠 `NotFound` 区分「目录不存在（正常空集）」
/// 和「真的读不了」。丢掉 kind 只剩字符串的话，这个区分就不存在了。
fn io_err(op: String, e: std::io::Error) -> Error {
    Error::Io(std::io::Error::new(e.kind(), format!("{op}: {e}")))
}

fn io_ctx<T>(op: String, r: std::io::Result<T>) -> Result<T> {
    r.map_err(|e| io_err(op, e))
}

/// 把预置项展开成规则实际使用的匹配材料。
///
/// 语义：**并集**。预置项提供服务器侧数据，用户在规则里自己写的
/// `targets`/`ports`/`domains` 仍然有效（例如「预置项 + 我自己的一条附加网段」）。
/// 若两者都空，`compile` 会拒绝该规则（无目的条件 ⇒ 命中全部新建连接）。
pub fn expanded(p: &Preset, extra_targets: &[String]) -> Result<(Addrs, Vec<String>, Vec<String>)> {
    let mut addrs = matchers::split_normalize(&p.targets, "预置项目标")?;
    let extra = matchers::split_normalize(extra_targets, "规则目标")?;
    addrs.extend_sorted(&extra);
    let ports = matchers::normalize_ports(&p.ports)?;
    let domains = matchers::normalize_domains(&p.domains)?;
    Ok((addrs, ports, domains))
}

#[cfg(test)]
mod tests {
    use super::*;

    const OK: &str = r#"{
      "presets": [{
        "id": "demo",
        "label": "示例",
        "source": "管理员核对自官方清单",
        "targets": ["203.0.113.0/24"],
        "ports": ["30000-30100"],
        "proto": "udp",
        "domains": []
      }]
    }"#;

    #[test]
    fn parses_and_validates_ok() {
        let v = parse_text(OK, "t.json").unwrap();
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].id, "demo");
        assert_eq!(v[0].proto, ProtoFilter::Udp);
        assert_eq!(v[0].targets, vec!["203.0.113.0/24".to_string()]);
    }

    #[test]
    fn no_preset_is_bundled_in_code() {
        // 「绝不编造服务器 IP」的执行证据：
        // 本模块没有任何返回内置清单的函数，能加载到的预置项只能来自磁盘上的 JSON。
        // 全新安装（目录不存在）⇒ 空表且不报错，这正是发布物的真实状态。
        let missing = std::path::Path::new("/tmp/smw-definitely-missing-dir");
        assert!(load_dir(missing).unwrap().is_empty());
        assert!(!Path::new(PRESET_DIR).join("builtin-demo.json").exists());
    }

    #[test]
    fn loads_directory_sorted_and_rejects_cross_file_dupes() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(
            dir.path().join("b.json"),
            r#"[{"id":"zebra","source":"x","targets":["203.0.113.9"]}]"#,
        )
        .unwrap();
        std::fs::write(
            dir.path().join("a.json"),
            r#"{"presets":[{"id":"alpha","source":"y","targets":["198.51.100.0/24"]}]}"#,
        )
        .unwrap();
        // 非 .json 与子目录必须被忽略。
        std::fs::write(dir.path().join("notes.txt"), "hello").unwrap();
        std::fs::create_dir(dir.path().join("sub.json")).unwrap();
        let v = load_dir(dir.path()).unwrap();
        assert_eq!(
            v.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
            vec!["alpha", "zebra"]
        );

        std::fs::write(
            dir.path().join("c.json"),
            r#"[{"id":"alpha","source":"z","targets":["198.51.100.1"]}]"#,
        )
        .unwrap();
        let e = load_dir(dir.path()).unwrap_err().to_string();
        assert!(e.contains("重复"), "{e}");

        // 坏 JSON 整批失败，不静默跳过该文件。
        std::fs::remove_file(dir.path().join("c.json")).unwrap();
        std::fs::write(dir.path().join("d.json"), "{ broken").unwrap();
        assert!(load_dir(dir.path()).is_err());
    }

    #[test]
    fn duplicate_id_within_one_file_is_error() {
        // 与跨文件重复是两条不同的分支：这里必须在**同一个文件内**就拦住，
        // 否则后一条会覆盖前一条，用户看到「预置项存在」但用的是另一份地址。
        let s = r#"[{"id":"dup","source":"x","targets":["203.0.113.1"]},
                    {"id":"dup","source":"y","targets":["198.51.100.1"]}]"#;
        let e = parse_text(s, "t.json").unwrap_err().to_string();
        assert!(e.contains("重复") && e.contains("t.json"), "{e}");
    }

    #[test]
    fn missing_source_is_error() {
        let s = r#"{"presets":[{"id":"a","targets":["203.0.113.0/24"]}]}"#;
        let e = parse_text(s, "t.json").unwrap_err().to_string();
        assert!(e.contains("source"), "{e}");
    }

    #[test]
    fn empty_targets_is_error() {
        let s = r#"{"presets":[{"id":"a","source":"x","targets":[]}]}"#;
        let e = parse_text(s, "t.json").unwrap_err().to_string();
        assert!(e.contains("太危险"), "{e}");
        // 只有域名也算有目的条件。
        let s2 = r#"{"presets":[{"id":"a","source":"x","domains":["a.example"]}]}"#;
        assert!(parse_text(s2, "t.json").is_ok());
    }

    #[test]
    fn bad_proto_and_dup_id_and_bad_cidr_rejected() {
        let s = r#"{"presets":[{"id":"a","source":"x","targets":["1.2.3.4"],"proto":"sctp"}]}"#;
        assert!(parse_text(s, "t.json")
            .unwrap_err()
            .to_string()
            .contains("proto"));
        let s = r#"{"presets":[
            {"id":"a","source":"x","targets":["1.2.3.4"]},
            {"id":"a","source":"x","targets":["1.2.3.5"]}
        ]}"#;
        assert!(parse_text(s, "t.json")
            .unwrap_err()
            .to_string()
            .contains("重复"));
        let s = r#"{"presets":[{"id":"a","source":"x","targets":["1.2.3.4/40"]}]}"#;
        assert!(
            parse_text(s, "t.json").is_err(),
            "数据文件里的非法 CIDR 必须在加载时就报错"
        );
        assert!(parse_text("{ not json", "t.json").is_err());
        // 未知字段被容忍（向前兼容），不影响解析。
        let s = r#"{"presets":[{"id":"a","source":"x","targets":["1.2.3.4"],"future":"ok"}]}"#;
        assert_eq!(parse_text(s, "t.json").unwrap().len(), 1);
    }

    #[test]
    fn id_charset_enforced() {
        // id 会进 nft 对象名：`;`、空格、引号一律拒绝。
        for bad in ["a b", "a;b", r#"a"b"#, "a/b", &"x".repeat(41)] {
            let s =
                format!(r#"{{"presets":[{{"id":"{bad}","source":"x","targets":["1.2.3.4"]}}]}}"#);
            assert!(parse_text(&s, "t.json").is_err(), "应拒绝 id={bad:?}");
        }
    }

    #[test]
    fn expanded_is_union_of_preset_and_rule() {
        let p = Preset {
            id: "demo".into(),
            label: String::new(),
            source: "x".into(),
            updated: String::new(),
            targets: vec!["203.0.113.0/24".into()],
            ports: vec!["30000-30100".into()],
            proto: ProtoFilter::Udp,
            domains: vec!["a.example".into()],
        };
        let (addrs, ports, domains) =
            expanded(&p, &["198.51.100.0/24".into(), "203.0.113.0/24".into()]).unwrap();
        assert_eq!(
            addrs.v4,
            vec!["198.51.100.0/24".to_string(), "203.0.113.0/24".to_string()],
            "并集 + 排序 + 去重"
        );
        assert_eq!(ports, vec!["30000-30100".to_string()]);
        assert_eq!(domains, vec!["a.example".to_string()]);
    }

    #[test]
    fn top_level_single_object_supported() {
        let s = r#"{"id":"solo","source":"x","targets":["203.0.113.0/24"]}"#;
        let v = parse_text(s, "t.json").unwrap();
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].id, "solo");
    }
}
