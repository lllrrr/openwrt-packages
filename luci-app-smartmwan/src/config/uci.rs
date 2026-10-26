//! UCI 文本格式的原生解析与序列化。
//!
//! 为什么不链接 libuci：FFI 会破坏可复现交叉构建，且 libuci 的 `uci_set()` 语义会
//! 重写整个 section（丢失注释与未知字段）。本项目要求「不得覆盖用户手工维护的字段」，
//! 因此这里做的是**结构化保真编辑**：解析成保留顺序的 AST，改我们拥有的键，
//! 其余原样写回。
//!
//! 支持的语法（与 OpenWrt libuci 文件解析器一致的实际子集）：
//!
//! ```text
//! # 注释
//! config <类型> '<段名>'       # 具名段
//! config <类型>               # 匿名段
//! option <键> '<值>'
//! option <键>=<值>            # 部分老文件这样写，容错接受
//! list <键> '<v1>' '<v2>'     # 同一行多个值
//! ```
//!
//! 值内单引号按 `\'` 转义；`\\` 表示反斜杠本身。

use std::fmt::Write as _;
use std::path::Path;

use crate::{Error, Result};

/// 一个 UCI 条目前项：键值、键值列表或注释（注释必须保留，否则用户手写内容会丢）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    Option {
        key: String,
        value: String,
    },
    List {
        key: String,
        values: Vec<String>,
    },
    /// 原样保存的注释行（含缩进），用于回写。
    Comment(String),
}

/// 一个 section（`config type 'name'` 及其下属条目）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    /// `config` 后的类型名，例如 `smartmwan`、`wan`、`game`。
    pub stype: String,
    /// 段名；匿名段为 `None`。
    pub name: Option<String>,
    /// 条目按原文件顺序保存；顺序即 `uci show` 的显示顺序，也是 `order` 语义的基础。
    pub entries: Vec<Entry>,
}

/// 整个 UCI 配置文件。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct UciFile {
    /// 文件头注释块。
    pub head: Vec<String>,
    pub sections: Vec<Section>,
}

/// 单行解析出的原始指令。
enum Line {
    Blank,
    Comment(String),
    Config { stype: String, name: Option<String> },
    Option { key: String, value: String },
    List { key: String, values: Vec<String> },
}

fn unquote(tok: &str) -> Result<String> {
    let t = tok.trim();
    if t.is_empty() {
        return Ok(String::new());
    }
    let bytes = t.as_bytes();
    let quoted = (bytes[0] == b'\'' && bytes.last() == Some(&b'\'') && t.len() >= 2)
        || (bytes[0] == b'"' && bytes.last() == Some(&b'"') && t.len() >= 2);
    let inner = if quoted { &t[1..t.len() - 1] } else { t };
    // 反转义：\' -> '，\\ -> \，\n -> 换行（libuci 兼容）
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('\'') => out.push('\''),
            Some('"') => out.push('"'),
            Some('\\') => out.push('\\'),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            // 未知转义按字面保留，绝不吞掉用户数据。
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    Ok(out)
}

fn quote(value: &str) -> String {
    let mut s = String::with_capacity(value.len() + 3);
    s.push('\'');
    for c in value.chars() {
        match c {
            '\'' => s.push_str("\\'"),
            '\\' => s.push_str("\\\\"),
            '\n' => s.push_str("\\n"),
            '\t' => s.push_str("\\t"),
            _ => s.push(c),
        }
    }
    s.push('\'');
    s
}

/// 词法切分：尊重引号内的空格，因为 `option name 'a b'` 是合法的。
fn tokens(line: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_q = false;
    let mut escaped = false;
    for c in line.chars() {
        if escaped {
            // 保留 `\` + 被转义字符 这一对，交给 unquote 还原；
            // 此处若再补一个 `\'` 就会变成双重转义（`\\'`），还原后剩下字面反斜杠。
            cur.push('\\');
            cur.push(c);
            escaped = false;
            continue;
        }
        if c == '\\' && in_q {
            escaped = true;
            continue;
        }
        if c == '\'' {
            in_q = !in_q;
            cur.push(c);
            continue;
        }
        if c.is_whitespace() && !in_q {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            continue;
        }
        cur.push(c);
    }
    if in_q {
        return Err(Error::Config(format!(
            "未闭合的引号：{}",
            crate::clamp_str(line, 80)
        )));
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    Ok(out)
}

fn parse_line(raw: &str) -> Result<Line> {
    let line = raw.trim_end();
    if line.trim().is_empty() {
        return Ok(Line::Blank);
    }
    if line.trim_start().starts_with('#') {
        return Ok(Line::Comment(raw.to_string()));
    }
    let toks = tokens(line)?;
    let Some(head) = toks.first() else {
        return Ok(Line::Blank);
    };
    match head.as_str() {
        "config" => {
            let stype = toks
                .get(1)
                .map(|s| unquote(s))
                .transpose()?
                .unwrap_or_default();
            if stype.is_empty() {
                return Err(Error::Config(format!(
                    "缺少类型的 config 行：{}",
                    crate::clamp_str(line, 80)
                )));
            }
            let name = match toks.get(2) {
                Some(n) => Some(unquote(n)?),
                None => None,
            };
            Ok(Line::Config { stype, name })
        }
        "option" => {
            // 兼容 `option key=value`
            if toks.len() >= 2 {
                if let Some((k, v)) = toks[1].split_once('=') {
                    if toks.len() == 2 {
                        return Ok(Line::Option {
                            key: unquote(k)?,
                            value: unquote(v)?,
                        });
                    }
                }
            }
            let key = toks
                .get(1)
                .map(|s| unquote(s))
                .transpose()?
                .ok_or_else(|| {
                    Error::Config(format!("option 缺少键：{}", crate::clamp_str(line, 80)))
                })?;
            // UCI 允许空值：`option x ''`；缺省值按空串处理。
            let value = match toks.get(2) {
                Some(v) => unquote(v)?,
                None => String::new(),
            };
            Ok(Line::Option { key, value })
        }
        "list" => {
            let key = toks
                .get(1)
                .map(|s| unquote(s))
                .transpose()?
                .ok_or_else(|| {
                    Error::Config(format!("list 缺少键：{}", crate::clamp_str(line, 80)))
                })?;
            let mut values = Vec::with_capacity(toks.len().saturating_sub(2));
            for v in &toks[2..] {
                values.push(unquote(v)?);
            }
            Ok(Line::List { key, values })
        }
        other => Err(Error::Config(format!(
            "无法识别的指令 `{other}`：{}",
            crate::clamp_str(line, 80)
        ))),
    }
}

impl UciFile {
    pub fn parse(text: &str) -> Result<UciFile> {
        Self::parse_report(text).map(|(f, _)| f)
    }

    /// 解析并返回（文件, 非致命告警列表）。行号必须带进错误信息，
    /// 否则用户面对一个 400 行的配置文件无从下手。
    pub fn parse_report(text: &str) -> Result<(UciFile, Vec<String>)> {
        let mut file = UciFile::default();
        let mut warnings = Vec::new();
        let mut current: Option<Section> = None;
        for (idx, raw) in text.lines().enumerate() {
            let lineno = idx + 1;
            match parse_line(raw) {
                Ok(Line::Blank) => {
                    // 段内空行保留为注释占位，避免回写后排版塌陷
                    if let Some(sec) = current.as_mut() {
                        if !sec.entries.is_empty() {
                            sec.entries.push(Entry::Comment(String::new()));
                        }
                    } else if !raw.trim().is_empty() {
                        warnings.push(format!("第 {lineno} 行：段外空白"));
                    } else if file.head.is_empty() || raw.is_empty() {
                        file.head.push(String::new());
                    }
                }
                Ok(Line::Comment(c)) => match current.as_mut() {
                    Some(sec) => sec.entries.push(Entry::Comment(c)),
                    None => file.head.push(c),
                },
                Ok(Line::Config { stype, name }) => {
                    if let Some(sec) = current.take() {
                        file.sections.push(sec);
                    }
                    current = Some(Section {
                        stype,
                        name,
                        entries: Vec::new(),
                    });
                }
                Ok(Line::Option { key, value }) => {
                    // 段外的 option 是损坏文件；报错而不是猜它属于哪一段。
                    let sec = current.as_mut().ok_or_else(|| {
                        Error::Config(format!("第 {lineno} 行：option 出现在任何 config 之前"))
                    })?;
                    merge_option(sec, &key, value);
                }
                Ok(Line::List { key, values }) => {
                    let sec = current.as_mut().ok_or_else(|| {
                        Error::Config(format!("第 {lineno} 行：list 出现在任何 config 之前"))
                    })?;
                    merge_list(sec, &key, values);
                }
                Err(e) => {
                    // 单行语法错误不丢弃整个文件：记录告警继续，交由校验层决定是否致命。
                    warnings.push(format!("第 {lineno} 行：{e}"));
                }
            }
        }
        if let Some(sec) = current.take() {
            file.sections.push(sec);
        }
        Ok((file, warnings))
    }

    pub fn render(&self) -> String {
        let mut out = String::with_capacity(self.sections.len() * 128 + 64);
        for h in &self.head {
            let t = h.trim();
            if t.is_empty() {
                out.push('\n');
            } else {
                let _ = writeln!(out, "{t}");
            }
        }
        if !self.head.is_empty() && !self.sections.is_empty() {
            // 头部与首个段之间固定一个空行
            if !out.ends_with("\n\n") {
                out.push('\n');
            }
        }
        for sec in &self.sections {
            match &sec.name {
                Some(n) => {
                    let _ = writeln!(out, "config {} {}", sec.stype, quote(n));
                }
                None => {
                    let _ = writeln!(out, "config {}", sec.stype);
                }
            }
            for e in &sec.entries {
                match e {
                    Entry::Comment(c) => {
                        let t = c.trim();
                        if t.is_empty() {
                            out.push('\n');
                        } else {
                            let _ = writeln!(out, "\t{t}");
                        }
                    }
                    Entry::Option { key, value } => {
                        let _ = writeln!(out, "\toption {} {}", key, quote(value));
                    }
                    Entry::List { key, values } => {
                        // 每项一行，符合 UCI 惯例，也便于 `uci add_list/del_list` 对齐。
                        for v in values {
                            let _ = writeln!(out, "\tlist {} {}", key, quote(v));
                        }
                    }
                }
            }
        }
        out
    }

    /// 读取 `config <stype> '<name>'` 段。
    pub fn section(&self, stype: &str, name: &str) -> Option<&Section> {
        self.sections
            .iter()
            .find(|s| s.stype == stype && s.name.as_deref() == Some(name))
    }

    /// 返回所有该类型段（含匿名段），保持文件顺序。
    pub fn sections_of(&self, stype: &str) -> Vec<&Section> {
        self.sections.iter().filter(|s| s.stype == stype).collect()
    }

    pub fn get_option(&self, stype: &str, name: &str, key: &str) -> Option<&str> {
        let sec = self.section(stype, name)?;
        sec.entries.iter().find_map(|e| match e {
            Entry::Option { key: k, value } if k == key => Some(value.as_str()),
            _ => None,
        })
    }
}

impl Section {
    pub fn option(&self, key: &str) -> Option<String> {
        self.entries.iter().find_map(|e| match e {
            Entry::Option { key: k, value } if k == key => Some(value.clone()),
            _ => None,
        })
    }

    /// 列表值：跨多行 `list` 聚合，保持顺序。
    pub fn list(&self, key: &str) -> Vec<String> {
        let mut out = Vec::new();
        for e in &self.entries {
            if let Entry::List { key: k, values } = e {
                if k == key {
                    out.extend(values.iter().cloned());
                }
            }
        }
        out
    }

    /// 设置标量：存在则就地替换（保持位置），否则追加到段尾（注释之前）。
    pub fn set_option(&mut self, key: &str, value: &str) {
        for e in self.entries.iter_mut() {
            if let Entry::Option { key: k, value: v } = e {
                if k == key {
                    *v = value.to_string();
                    return;
                }
            }
        }
        self.insert_at_tail(Entry::Option {
            key: key.to_string(),
            value: value.to_string(),
        });
    }

    /// 整体替换列表（值个数可变）；空列表删除该键而不是留空行。
    pub fn set_list(&mut self, key: &str, values: &[String]) {
        self.remove_key(key);
        if values.is_empty() {
            return;
        }
        self.insert_at_tail(Entry::List {
            key: key.to_string(),
            values: values.to_vec(),
        });
    }

    pub fn remove_key(&mut self, key: &str) {
        self.entries.retain(|e| match e {
            Entry::Option { key: k, .. } => k != key,
            Entry::List { key: k, .. } => k != key,
            Entry::Comment(_) => true,
        });
    }

    fn insert_at_tail(&mut self, entry: Entry) {
        // 插到最后一条非注释条目之后，让注释留在段尾装饰位。
        let mut idx = self.entries.len();
        while idx > 0 {
            if !matches!(self.entries[idx - 1], Entry::Comment(_)) {
                break;
            }
            idx -= 1;
        }
        self.entries.insert(idx, entry);
    }
}

/// 同名 `option` 重复出现时：后写覆盖先写（与 libuci 行为一致），但要保留首行位置，
/// 并把多余项删除 —— 否则回写会留下重复键，`uci show` 只显示最后一个，用户改不到。
fn merge_option(sec: &mut Section, key: &str, value: String) {
    let existing = sec
        .entries
        .iter_mut()
        .filter(|e| matches!(e, Entry::Option{key: k,..} if k == key))
        .collect::<Vec<_>>();
    if let Some(first) = existing.into_iter().next() {
        if let Entry::Option { value: v, .. } = first {
            *v = value;
        }
        // 去重：只留一个
        let mut seen = false;
        sec.entries.retain(|e| match e {
            Entry::Option { key: k, .. } if k == key => {
                if seen {
                    false
                } else {
                    seen = true;
                    true
                }
            }
            _ => true,
        });
        return;
    }
    // option 与 list 同名是非法的（UCI 不允许），这里把已存在的 list 转成 option，
    // 并在渲染时保持单键 —— 校验层会另行报告这种历史脏数据。
    sec.remove_key(key);
    sec.insert_at_tail(Entry::Option {
        key: key.to_string(),
        value,
    });
}

/// `list` 合并：同键多行追加；若某行给了多个值也全部收下。
fn merge_list(sec: &mut Section, key: &str, values: Vec<String>) {
    for e in sec.entries.iter_mut() {
        if let Entry::List { key: k, values: v } = e {
            if k == key {
                v.extend(values);
                return;
            }
        }
    }
    sec.entries.push(Entry::List {
        key: key.to_string(),
        values,
    });
}

/// 原子写：临时文件 → fsync → rename → fsync 目录。
/// 路由器上掉电不能留下半个配置文件，否则下次启动直接失去管理线路。
pub fn write_atomic(path: &Path, content: &str) -> Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| Error::Config(format!("路径无父目录：{}", path.display())))?;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(
        ".{}.tmp-{}",
        path.file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "uci".to_string()),
        std::process::id()
    ));
    {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp)?;
        use std::io::Write;
        f.write_all(content.as_bytes())?;
        f.flush()?;
        f.sync_all()?;
        let mut perms = std::fs::metadata(&tmp)?.permissions();
        perms.set_mode(0o600);
        std::fs::set_permissions(&tmp, perms)?;
    }
    std::fs::rename(&tmp, path).map_err(|e| {
        std::fs::remove_file(&tmp).ok();
        Error::Config(format!("原子替换失败 {}: {e}", path.display()))
    })?;
    // 目录 fsync：保证 rename 落盘（部分文件系统 rename 只写 journal）。
    if let Ok(d) = std::fs::File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(())
}

// 需要 unix 扩展 trait 才有 set_mode
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[cfg(not(unix))]
trait PermissionsExt {
    fn set_mode(&mut self, mode: u32);
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"# smartmwan 配置
# 由用户手工维护

config smartmwan 'global'
	option enabled '1'
	option mode 'balance'
	list probe_target '1.1.1.1'
	list probe_target '8.8.4.4'

config wan 'wan'
	option device 'eth1'
	option weight '4'
	# 行内注释要保住

config wan 'wan2'
	option device 'wwan0'
	option enabled '0'
"#;

    #[test]
    fn parse_sections_and_values() {
        let f = UciFile::parse(SAMPLE).unwrap();
        assert_eq!(f.sections.len(), 3);
        assert_eq!(f.get_option("smartmwan", "global", "mode"), Some("balance"));
        assert_eq!(
            f.section("wan", "wan").unwrap().list("probe_target"),
            Vec::<String>::new()
        );
        assert_eq!(
            f.section("smartmwan", "global")
                .unwrap()
                .list("probe_target"),
            vec!["1.1.1.1".to_string(), "8.8.4.4".to_string()]
        );
        assert_eq!(f.get_option("wan", "wan2", "enabled"), Some("0"));
        assert_eq!(f.sections_of("wan").len(), 2);
    }

    #[test]
    fn roundtrip_is_stable_and_keeps_comments() {
        let f = UciFile::parse(SAMPLE).unwrap();
        let rendered = f.render();
        let g = UciFile::parse(&rendered).unwrap();
        assert_eq!(f, g, "解析→渲染→解析 必须完全等价");
        assert!(rendered.contains("行内注释要保住"));
        assert!(rendered.contains("# smartmwan 配置"));
    }

    #[test]
    fn set_option_preserves_position_and_unknown_keys() {
        let mut f = UciFile::parse(SAMPLE).unwrap();
        let sec = f
            .sections
            .iter_mut()
            .find(|s| s.name.as_deref() == Some("global"))
            .unwrap();
        sec.set_option("mode", "failover");
        sec.set_option("brand_new_key", "42"); // 未来版本新增键，写回应保留
        let text = f.render();
        let g = UciFile::parse(&text).unwrap();
        assert_eq!(
            g.get_option("smartmwan", "global", "mode"),
            Some("failover")
        );
        assert_eq!(
            g.get_option("smartmwan", "global", "brand_new_key"),
            Some("42")
        );
        // mode 仍应在 enabled 之后（就地替换，不移动）
        let order: Vec<String> = g
            .section("smartmwan", "global")
            .unwrap()
            .entries
            .iter()
            .filter_map(|e| match e {
                Entry::Option { key, .. } => Some(key.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(order[0], "enabled");
        assert_eq!(order[1], "mode");
    }

    #[test]
    fn duplicate_option_is_collapsed() {
        let f = UciFile::parse("config a 'b'\n\toption x '1'\n\toption x '2'\n").unwrap();
        let s = f.section("a", "b").unwrap();
        let cnt = s
            .entries
            .iter()
            .filter(|e| matches!(e, Entry::Option{key,..} if key == "x"))
            .count();
        assert_eq!(cnt, 1, "重复 option 必须合并，避免回写留残");
        assert_eq!(
            s.option("x").as_deref(),
            Some("2"),
            "后值生效，与 libuci 一致"
        );
    }

    #[test]
    fn quoting_roundtrip_escapes_specials() {
        let mut f = UciFile::default();
        let mut s = Section {
            stype: "game".into(),
            name: Some("it's \"ok\"".into()),
            entries: vec![],
        };
        s.set_list("target", &["203.0.113.0/24".into(), "with space".into()]);
        s.set_option("note", "line\nbreak");
        f.sections.push(s);
        let text = f.render();
        let g = UciFile::parse(&text).unwrap();
        assert_eq!(g.sections[0].name.as_deref(), Some("it's \"ok\""));
        assert_eq!(g.sections[0].list("target")[1], "with space");
        assert_eq!(g.sections[0].option("note").unwrap(), "line\nbreak");
    }

    #[test]
    fn accepts_equals_syntax_and_empty_value() {
        let f = UciFile::parse("config a 'b'\n\toption k=v\n\toption e ''\n").unwrap();
        assert_eq!(f.get_option("a", "b", "k"), Some("v"));
        assert_eq!(f.get_option("a", "b", "e"), Some(""));
    }

    #[test]
    fn reports_unclosed_quote_as_warning() {
        let (_, warns) = UciFile::parse_report("config a 'b'\n\toption k 'unclosed\n").unwrap();
        assert!(!warns.is_empty(), "语法问题必须报告而不是静默忽略");
        assert!(warns[0].contains("第 2 行"), "错误必须带行号: {:?}", warns);
    }

    #[test]
    fn option_before_any_config_is_fatal() {
        let e = UciFile::parse("\toption k 'v'\n").unwrap_err();
        assert!(e.to_string().contains("任何 config 之前"), "{e}");
    }

    #[test]
    fn atomic_write_sets_owner_only_perms() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("smartmwan");
        write_atomic(&p, "config a 'b'\n").unwrap();
        let got = std::fs::read_to_string(&p).unwrap();
        assert_eq!(got, "config a 'b'\n");
        let mode = std::fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "配置文件含可执行策略，默认应仅 root 可读写");
        // 不应留下临时文件
        let leftovers = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .count();
        assert_eq!(leftovers, 0);
    }

    #[test]
    fn anonymous_sections_are_supported() {
        let f = UciFile::parse(
            "config route\n\toption target '0.0.0.0/0'\nconfig route\n\toption target ' ::/0 '\n",
        )
        .unwrap();
        assert_eq!(f.sections_of("route").len(), 2);
        assert!(f.sections_of("route")[0].name.is_none());
        // libuci 保留引号内的空白：引号就是用户表达“这就是值”的方式。
        // 取值层的 trim 由 config::mod 的 option_str/option_num 负责，
        // 这里不做二次清洗，否则无法原样回写用户文件。
        assert_eq!(
            f.sections_of("route")[1].option("target").as_deref(),
            Some(" ::/0 ")
        );
        assert_eq!(
            f.sections_of("route")[1]
                .option("target")
                .map(|v| v.trim().to_string())
                .as_deref(),
            Some("::/0")
        );
        // 原样回写不能破坏匿名段（段名一个都不能多出来）
        let out = f.render();
        let again = UciFile::parse(&out).unwrap();
        assert_eq!(again.sections_of("route").len(), 2);
        assert_eq!(
            again.sections_of("route")[1].option("target"),
            Some(" ::/0 ".to_string())
        );
    }
}
