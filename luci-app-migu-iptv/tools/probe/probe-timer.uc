#!/usr/bin/ucode
// 探测 ucode uloop timer 对象有哪些可用方法
import * as uloop from 'uloop';

let t = uloop.timer(100000, () => {});
printf('timer type: %s\n', type(t));
printf('has cancel: %s\n', (type(t.cancel) === 'function') ? 'YES' : 'NO');
printf('has set: %s\n', (type(t.set) === 'function') ? 'YES' : 'NO');
printf('has remaining: %s\n', (type(t.remaining) === 'function') ? 'YES' : 'NO');
let keys = [];
for (let k in t) push(keys, k);
printf('keys: %s\n', join(',', keys));
if (type(t.cancel) === 'function') {
	t.cancel();
	printf('cancel() OK\n');
}
