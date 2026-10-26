'use strict';

// 通用 webhook：POST JSON（M3 的刷写事件也走这里）
// 约定：字段只加不减；未配置 webhook 时静默跳过。

let util = require('rtfwupgrade.util');

function post(url, payload) {
	if (!length(trim(url ?? '')))
		return { ok: false, skipped: true };

	let body = sprintf('%J', payload);
	let res = util.run(sprintf('curl -fsS -m 15 -X POST -H %s --data-binary %s --url %s 2>/dev/null',
		util.shquote('Content-Type: application/json'), util.shquote(body), util.shquote(url)));

	return { ok: res.code == 0, code: res.code, error: res.code == 0 ? '' : 'webhook 投递失败' };
}

function payload(event, local, remote, extra) {
	let img = remote?.image ?? {};
	let out = {
		event: event,
		ts: util.now_epoch(),
		device: {
			hostname: local?.hostname ?? '',
			model: local?.model ?? '',
			board_name: local?.board_name ?? ''
		},
		local: {
			build_id: local?.build_id ?? '',
			build_date: local?.build_date ?? 0,
			channel: local?.version ?? ''
		},
		remote: {
			source: remote?.source ?? '',
			build_id: remote?.version_code ?? '',
			build_date: remote?.source_date_epoch ?? 0,
			channel: remote?.channel ?? '',
			image: {
				name: img.name ?? '',
				size: img.size ?? 0,
				sha256: img.sha256 ?? ''
			}
		},
		state: extra?.state ?? ''
	};

	for (let k in keys(extra ?? {}))
		if (k != 'state')
			out[k] = extra[k];

	return out;
}

return {
	post: post,
	payload: payload
};
