// ucode split / trim 语义测试（独立文件，避免 -e 转义干扰）
let out = "alpha\nbeta\ngamma\n";

print("=== A. split('\\n', out) —— 分隔符在前 ===\n");
let a = split("\n", out);
print("length = " + length(a) + "  %J = " + sprintf("%J", a) + "\n");

print("\n=== B. split(out, '\\n') —— 字符串在前（若上一行为 1，则参数序反了）===\n");
let b = split(out, "\n");
print("length = " + length(b) + "  %J = " + sprintf("%J", b) + "\n");

print("\n=== C. 真实 EPG 管道输出形状（含空行/CR）===\n");
let raw = "id1\nid2\n\nid3\n";
let c = split("\n", raw);
print("split 结果 length = " + length(c) + "  %J = " + sprintf("%J", c) + "\n");
let kept = [];
for (let t in c) { if (trim(t) != "") push(kept, trim(t)); }
print("trim 过滤后 = " + sprintf("%J", kept) + "  length=" + length(kept) + "\n");

print("\n=== D. trim 对 CR 与空白的行为 ===\n");
print("trim('a\\r') = " + sprintf("%J", trim("a\r")) + "\n");
print("trim('\\r') 长度 = " + length(trim("\r")) + "\n");
print("trim('  x  ') = " + sprintf("%J", trim("  x  ")) + "\n");

print("\n=== E. 用 sed 结果文件（124 行）真实解析 ===\n");
let fs = require("fs");
if (fs.access("/tmp/epg-sed.txt")) {
  let content = fs.readfile("/tmp/epg-sed.txt");
  print("文件字节数 = " + length(content) + "\n");
  let lines = split("\n", content);
  print("split 后 length = " + length(lines) + "\n");
  print("前 6 个 = " + sprintf("%J", slice(lines, 0, 6)) + "\n");
  let ids = [];
  for (let t in lines) { let s = trim(t); if (s != "") push(ids, s); }
  print("过滤后 id 数 = " + length(ids) + "\n");
  print("含 CCTV5+ ? " + (index(ids, "CCTV5+") >= 0) + "\n");
} else {
  print("(sed 结果文件不存在)\n");
}

print("\n=== F. 原 grep 管道结果文件（20 行）真实解析 ===\n");
if (fs.access("/tmp/epg-orig.txt")) {
  let content = fs.readfile("/tmp/epg-orig.txt");
  let lines = split("\n", content);
  let ids = [];
  for (let t in lines) { let s = trim(t); if (s != "") push(ids, s); }
  print("过滤后 id 数 = " + length(ids) + "  %J = " + sprintf("%J", ids) + "\n");
} else {
  print("(orig 结果文件不存在)\n");
}

print("\n=== G. 若 out 为空串时的行为（失败路径）===\n");
let empty = "";
let g = split("\n", empty);
print("length = " + length(g) + "  %J = " + sprintf("%J", g) + "\n");
let idsG = [];
for (let t in g) { let s = trim(t); if (s != "") push(idsG, s); }
print("过滤后 = " + length(idsG) + "\n");
