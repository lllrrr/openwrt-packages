'use strict';
'require baseclass';

/*
 * 分块上传：把整份内容切成小块，分多次 JSON-RPC 请求送上去。
 *
 * 为什么不干脆一次把整份配置塞进一个请求：/ubus 的请求体上限不是"超了给个
 * 错误"那么温和，nginx 那条路径是直接把 worker 干掉的。
 *
 *   * uhttpd-mod-ubus：UH_UBUS_MAX_POST_SIZE = 65536，超了中途放弃解析并关闭
 *     连接（uhttpd/ubus.c）。
 *   * nginx 的 ubus 模块：请求体超过 client_body_buffer_size（nginx 默认两个
 *     内存页，即 8192）时 nginx 把 body 落到临时文件，buf 变成文件 buf（pos
 *     为 NULL，长度取文件长度），模块却用
 *     ngx_memcpy(buffer + pos, in->buf->pos, len) 去拷它
 *     ⇒ memcpy(dst, NULL, len) ⇒ worker SIGSEGV ⇒ 连接被重置，浏览器连一个
 *     HTTP 响应都拿不到，只报 XHR request aborted by browser。
 *       https://github.com/Ansuel/nginx-ubus-module/issues/2
 *
 * 所以每个请求体都必须远小于 8192：块取 2048 个字符，JSON 编码最坏翻一倍
 * （换行/引号/反斜杠都会变成两个字节），再加 JSON-RPC 外壳（约 300 字节），
 * 单次请求也就 4.4 KB 上下。服务端按同一套协议累加，见 luci.oxidns 里
 * resolve_content_file 上方的说明。
 */

/* 一块最多切多少个字符（不是字节：UTF-8 的多字节字符只占一个 JS 字符） */
var CHUNK_CHARS = 2048;

/* 一块 JSON 编码之后允许占多少字节，超了就切得更碎（防换行特别多的文件） */
var CHUNK_ENCODED_BYTES = 4096;

/*
 * 一块的真实 UTF-8 字节上限，必须与服务端的 UPLOAD_CHUNK_MAX_BYTES 一致。
 *
 * 只按字符数切块在多字节内容上会超：2048 个汉字就是 6144 字节，服务端拿
 * chunk_bytes 一比就回 upload_chunk_too_large —— 也就是说含中文的配置/规则
 * 文件一个都存不下去。字符数上限挡不住这个，字节数上限才挡得住。
 */
var CHUNK_BYTES_MAX = 4096;

/* 一份内容最多允许多大（服务端另有一道闸门，这里只是提前给个明确的错） */
var MAX_CONTENT_BYTES = 16 * 1024 * 1024;

function utf8Length(text) {
	var total = 0;

	for (var i = 0; i < text.length; i++) {
		var code = text.charCodeAt(i);

		if (code < 0x80)
			total += 1;
		else if (code < 0x800)
			total += 2;
		else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length &&
		         text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
			total += 4;
			i++;
		}
		else
			total += 3;
	}

	return total;
}

/* 纯 ASCII（没有引号、反斜杠和控制字符）时编码后长度就等于字符数 */
function isAscii(text) {
	return /^[\x20\x21\x23-\x5b\x5d-\x7e]*$/.test(text);
}

function encodedLength(text) {
	return isAscii(text) ? text.length : JSON.stringify(text).length - 2;
}

/*
 * 把内容切成分块描述：
 *   text     本块正文（尾随换行已摘掉）
 *   newlines 被摘掉的尾随换行个数
 *   bytes    本块真实字节数（UTF-8，含尾随换行）
 *   offset   本块之前所有块的字节数
 *
 * 摘掉尾随换行不是为了省字节，是必须的：服务端用命令替换取 JSON 字符串，
 * 而命令替换会吃掉所有尾随换行 —— 不把个数单独带过去，凡是落在块边界上的
 * 换行都会被静默吞掉，而"静默少几个字节"正是最难查的一类 bug。
 */
function planChunks(source, options) {
	var chunkChars = (options && options.chunkChars) || CHUNK_CHARS;
	var encodedMax = (options && options.encodedBytes) || CHUNK_ENCODED_BYTES;
	var bytesMax = (options && options.bytes) || CHUNK_BYTES_MAX;
	var list = [];
	var cursor = 0;
	var offset = 0;

	while (cursor < source.length) {
		var take = Math.min(chunkChars, source.length - cursor);
		var slice = source.substr(cursor, take);

		/* 两个上限都要压：encodedMax 管请求体别顶到 nginx 的 8192，bytesMax
		 * 管服务端的 chunk_bytes 闸门。按超得最狠的那个比例缩，一次到位。 */
		while (take > 1 && (encodedLength(slice) > encodedMax || utf8Length(slice) > bytesMax)) {
			var over = Math.max(encodedLength(slice) / encodedMax, utf8Length(slice) / bytesMax);
			take = Math.max(1, Math.floor(take / over));
			slice = source.substr(cursor, take);
		}

		/* 不要把代理对劈成两半：劈开之后两半都不是合法 UTF-8，字节数也对不上，
		 * 服务端的"payload 没被改过"体检会误报。往后挪一个字符即可。 */
		if (take < source.length - cursor) {
			var lastCode = source.charCodeAt(cursor + take - 1);
			if (lastCode >= 0xd800 && lastCode <= 0xdbff) {
				take -= 1;
				slice = source.substr(cursor, take);
			}
		}

		var body = slice.replace(/\n+$/, '');
		var newlines = slice.length - body.length;

		list.push({
			text: body,
			newlines: newlines,
			bytes: utf8Length(slice),
			offset: offset
		});

		offset += utf8Length(slice);
		cursor += take;
	}

	/* 空内容也要发一块，否则服务端收不到任何请求（它会照旧报"内容是空的"） */
	if (!list.length)
		list.push({ text: '', newlines: 0, bytes: 0, offset: 0 });

	return list;
}

function makeUploadId() {
	var alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
	var suffix = '';

	for (var i = 0; i < 12; i++)
		suffix += alphabet.charAt(Math.floor(Math.random() * alphabet.length));

	return 'u' + Date.now().toString(36) + suffix;
}

/*
 * 分块进度的显示后缀（纯函数，DOM 更新留给调用方）。
 * 块数太少时百分比只会闪一下、最后一块的 100% 也没意义，这两种情况返回空串。
 */
function progressSuffix(done, total) {
	if (total < 3)
		return '';

	var percent = Math.floor(done * 100 / total);

	if (percent >= 100)
		return '';

	return ' ' + percent + '%';
}

/*
 * 依次把每块交给 invoke(chunk, last, uploadId)，返回最后一块的结果。
 * 中间块必须拿到 pending 才继续 —— 服务端收下没存住时不能当成功。
 *
 * 注意"返回最后一块的结果"是真的要返回：收尾那一步如果不把末块的回包带出来
 * 而是 resolve(null)，调用方（config.js / rules.js）会拿 `!result` 判成失败，
 * 于是校验/保存明明成功也报错。
 */
function uploadText(text, invoke, onProgress) {
	var source = String(text === null || text === undefined ? '' : text);

	if (utf8Length(source) > MAX_CONTENT_BYTES)
		return Promise.resolve({
			ok: false,
			code: 'upload_too_large',
			message: 'content must stay below ' + MAX_CONTENT_BYTES + ' bytes'
		});

	var chunks = planChunks(source);
	var uploadId = makeUploadId();
	var index = 0;
	var lastResult = null;

	function step() {
		if (index >= chunks.length)
			return Promise.resolve(lastResult);

		var chunk = chunks[index];
		var last = (index === chunks.length - 1);

		return Promise.resolve(invoke(chunk, last, uploadId)).then(function(result) {
			if (result && result.ok === false)
				return result;

			if (!last && (!result || result.pending !== true))
				return {
					ok: false,
					code: 'upload_rejected',
					message: 'the service accepted a chunk without storing it'
				};

			lastResult = result;
			index++;

			if (onProgress)
				onProgress(index, chunks.length);

			return step();
		});
	}

	return step();
}

return baseclass.extend({
	chunkChars: CHUNK_CHARS,
	chunkEncodedBytes: CHUNK_ENCODED_BYTES,
	chunkBytesMax: CHUNK_BYTES_MAX,
	maxContentBytes: MAX_CONTENT_BYTES,
	utf8Length: utf8Length,
	encodedLength: encodedLength,
	isAscii: isAscii,
	planChunks: planChunks,
	progressSuffix: progressSuffix,
	uploadText: uploadText
});
