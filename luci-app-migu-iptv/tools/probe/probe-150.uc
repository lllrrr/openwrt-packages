#!/usr/bin/ucode
// probe-150.uc — 验证 1.5.0 用到的 ucode 特性：
//   1. 字符串 \x47 转义（MPEG-TS 同步字节 0x47）
//   2. delete 关键字删除对象键
//   3. 空字符串的 truthiness
let o = {};
o['a'] = 1;
o['b'] = 2;

// 1: \x47
let s = '\x47';
printf("hex47=[%s] len=%d\n", s, length(s));

// 2: delete
delete o['a'];
printf("after-delete a=%s b=%s\n", ('a' in o) ? 'present' : 'gone', o['b']);

// 3: empty string truthiness
let e = '';
if (e) printf("empty string is TRUTHY\n"); else printf("empty string is FALSY\n");
let f = '';
if (f === '') printf("eq-empty ok\n");

// 4: 2xx/3xx 判断模式里用到的比较
let code = '200';
let ok = (code[0] === '2' || code[0] === '3');
printf("code200 2xx/3xx=%s\n", ok ? 'yes' : 'no');

// 5: 字符串按数组下标访问首字符（epgIdFor 同款用法）
let name = 'CCTV1';
printf("first-char=[%s]\n", name[0]);

printf("PROBE_OK\n");