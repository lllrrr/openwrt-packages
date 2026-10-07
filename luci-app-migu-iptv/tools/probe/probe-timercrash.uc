#!/usr/bin/ucode
// 关键验证：定时器回调里抛异常，uloop 是否会终止进程
import * as uloop from 'uloop';

printf('start\n');

uloop.timer(50, () => {
	printf('6a. 回调即将抛错\n');
	let x = null;
	x.nonexistentMethodCall();   // 用真实运行时错误，而不是 throw 字面量
	printf('6a. 不该到达这里\n');
});

uloop.timer(400, () => {
	printf('6b. 进程仍活着 → 回调抛错没有终止 uloop\n');
	uloop.end();
});

uloop.run();
printf('end: uloop.run 已返回\n');
