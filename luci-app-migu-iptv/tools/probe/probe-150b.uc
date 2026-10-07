#!/usr/bin/ucode
// probe-150b.uc — 验证数值字符串比较 + 字符串首字符的两种取法
let code = '200';
let ok = (code >= 200 && code < 400);
printf("num-compare-200=%s\n", ok ? 'yes' : 'no');

let code2 = '304';
let ok2 = (code2 >= 200 && code2 < 400);
printf("num-compare-304=%s\n", ok2 ? 'yes' : 'no');

let code3 = '403';
let ok3 = (code3 >= 200 && code3 < 400);
printf("num-compare-403=%s\n", ok3 ? 'no' : 'BUG');

let code4 = '099';
let ok4 = (code4 >= 200 && code4 < 400);
printf("num-compare-099=%s\n", ok4 ? 'BUG' : 'no');

// 字符串首字符用 substr 没问题
let name = 'CCTV1';
let ch = substr(name, 0, 1);
printf("first-char-substr=[%s]\n", ch);

// 数组下标取元素没问题
let lines = split('a,b,c', ',');
printf("arr0=[%s] arr2=[%s]\n", lines[0], lines[2]);

printf("PROBE_OK\n");