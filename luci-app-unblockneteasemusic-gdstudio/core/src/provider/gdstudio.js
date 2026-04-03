const select = require('./select');
const request = require('../request');
const { getManagedCacheStorage } = require('../cache');

/**
 * GD Studio API 适配器
 * API 文档：https://music.gdstudio.xyz
 * 支持音乐源：netease、kuwo、joox、bilibili 等
 */

const format = (song) => ({
	id: song.id,
	name: song.name,
	duration: null, // GD Studio API 不返回时长，需要后续获取
	album: { id: null, name: song.album },
	artists: song.artist.map((name, index) => ({
		id: index ? null : song.id,
		name,
	})),
});

const search = (info) => {
	const keyword = encodeURIComponent(info.keyword);
	// 默认使用 netease 音乐源，也可以根据配置选择其他源
	const source = process.env.GDSTUDIO_SOURCE || 'netease';
	const url = `https://music-api.gdstudio.xyz/api.php?types=search&source=${source}&name=${keyword}&count=30&pages=1`;

	return request('GET', url)
		.then((response) => response.json())
		.then((jsonBody) => {
			if (!jsonBody || !Array.isArray(jsonBody) || jsonBody.length < 1)
				return Promise.reject();
			const list = jsonBody.map(format);
			const matched = select(list, info);
			return matched ? matched.id : Promise.reject();
		});
};

const track = (id) => {
	const source = process.env.GDSTUDIO_SOURCE || 'netease';
	// 默认使用最高音质 999
	const br = process.env.ENABLE_FLAC === 'true' ? '999' : '320';
	const url = `https://music-api.gdstudio.xyz/api.php?types=url&source=${source}&id=${id}&br=${br}`;

	return request('GET', url)
		.then((response) => response.json())
		.then((jsonBody) => {
			if (jsonBody && jsonBody.url) {
				return jsonBody.url;
			} else {
				return Promise.reject();
			}
		});
};

const cs = getManagedCacheStorage('provider/gdstudio');
const check = (info) => cs.cache(info, () => search(info)).then(track);

module.exports = { check, track };