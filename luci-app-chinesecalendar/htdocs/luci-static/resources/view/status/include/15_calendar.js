'use strict';
'require baseclass';

// ========== 农历压缩数据 ==========
// 每个条目编码一个农历年份的信息 (1900-2100)
// bit[16]: 闰月大小 (0=29天, 1=30天)
// bit[15:12]: 闰月月份 (0=无闰月, 1-12=闰几月)
// bit[11:0]: 12个月的大小 (bit0=正月, 1=30天大月, 0=29天小月)
var LUNAR_INFO = [
	0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2, // 1900-1909
	0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977, // 1910-1919
	0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970, // 1920-1929
	0x06566, 0x0d4a0, 0x0ea50, 0x16e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950, // 1930-1939
	0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557, // 1940-1949
	0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0, // 1950-1959
	0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0, // 1960-1969
	0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6, // 1970-1979
	0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570, // 1980-1989
	0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0, // 1990-1999
	0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5, // 2000-2009
	0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930, // 2010-2019
	0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530, // 2020-2029
	0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45, // 2030-2039
	0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0, // 2040-2049
	0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06aa0, 0x1a6c4, 0x0aae0, // 2050-2059
	0x092e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4, // 2060-2069
	0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0, // 2070-2079
	0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160, // 2080-2089
	0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a4d0, 0x0d150, 0x0f252, // 2090-2099
	0x0d520, // 2100
];

var BASE_YEAR = 1900;
// 1900年1月31日 = 农历庚子年正月初一
var BASE_DATE = new Date(1900, 0, 31);

var TIAN_GAN = ['甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸'];
var DI_ZHI = ['子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥'];
var SHENG_XIAO = ['鼠', '牛', '虎', '兔', '龙', '蛇', '马', '羊', '猴', '鸡', '狗', '猪'];
var NONG_YUE = ['正', '二', '三', '四', '五', '六', '七', '八', '九', '十', '冬', '腊'];
var NONG_RI = [
	'初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
	'十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
	'廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十',
];
var NONG_NIAN = ['〇', '一', '二', '三', '四', '五', '六', '七', '八', '九'];

// ========== 24节气 ==========
var SOLAR_TERMS = [
	'小寒', '大寒', '立春', '雨水', '惊蛰', '春分',
	'清明', '谷雨', '立夏', '小满', '芒种', '夏至',
	'小暑', '大暑', '立秋', '处暑', '白露', '秋分',
	'寒露', '霜降', '立冬', '小雪', '大雪', '冬至',
];

// 节气角度表 (每个节气对应太阳黄经角度)
// 小寒=285°, 大寒=300°, 立春=315°, ... 冬至=270°
// 按上面SOLAR_TERMS顺序, 从小寒(1月)开始
var TERM_ANGLES = [
	285, 300, 315, 330, 345, 0,
	15, 30, 45, 60, 75, 90,
	105, 120, 135, 150, 165, 180,
	195, 210, 225, 240, 255, 270,
];

// ========== 节日 ==========
var SOLAR_HOLIDAYS = {
	'0101': '元旦',
	'0214': '情人节',
	'0308': '妇女节',
	'0312': '植树节',
	'0401': '愚人节',
	'0501': '劳动节',
	'0504': '青年节',
	'0601': '儿童节',
	'0701': '建党节',
	'0801': '建军节',
	'0910': '教师节',
	'1001': '国庆节',
	'1225': '圣诞节',
};

var LUNAR_HOLIDAYS = {
	'0101': '春节',
	'0115': '元宵节',
	'0202': '龙抬头',
	'0303': '上巳节',
	'0505': '端午节',
	'0707': '七夕节',
	'0715': '中元节',
	'0815': '中秋节',
	'0909': '重阳节',
	'1001': '寒衣节',
	'1015': '下元节',
	'1208': '腊八节',
	'1223': '小年',
	'1230': '除夕',
};

// ========== 十二建星 (宜忌核心) ==========
var JIAN_XING = ['建', '除', '满', '平', '定', '执', '破', '危', '成', '收', '开', '闭'];

var JIAN_YI = {
	'建': '出行,上任,会友,上书,见大人',
	'除': '祭祀,求医,治病,扫舍,除灾',
	'满': '祈福,结婚,订婚,搬家,开市',
	'平': '修饰墙垣,平治道路,修造',
	'定': '祭祀,祈福,安床,修造,入学',
	'执': '祭祀,修造,办事,立券,捕捉',
	'破': '求医,治病,破屋,坏垣',
	'危': '祈福,祭祀,安床,结婚,收藏',
	'成': '结婚,开市,修造,搬家,立券',
	'收': '祈福,求嗣,纳财,收藏,开市',
	'开': '祈福,结婚,开市,动土,搬家',
	'闭': '祭祀,收藏,修造,安葬,筑堤',
};

var JIAN_JI = {
	'建': '动土,开仓,掘井,嫁娶',
	'除': '结婚,远行,开市,搬家',
	'满': '服药,栽种,掘井,动土',
	'平': '祈福,祭祀,求嗣,嫁娶',
	'定': '诉讼,出行,远行,动土',
	'执': '搬家,远行,出行,开市',
	'破': '祈福,结婚,开市,搬家',
	'危': '登高,行船,出行,搬家',
	'成': '诉讼,出行,开仓,动土',
	'收': '放债,出行,开渠,行船',
	'开': '放债,诉讼,安葬,破土',
	'闭': '开市,出行,结婚,求医',
};

// ========== 核心计算函数 ==========

// 获取农历年的总天数
function lunarYearDays(year) {
	var i, sum = 348;
	var info = LUNAR_INFO[year - BASE_YEAR];
	for (i = 0x800; i > 0x8; i >>= 1)
		sum += (info & i) ? 1 : 0;
	return sum + leapMonthDays(year);
}

// 获取农历年闰月的天数 (0表示无闰月)
function leapMonthDays(year) {
	var info = LUNAR_INFO[year - BASE_YEAR];
	if (leapMonth(year))
		return (info & 0x10000) ? 30 : 29;
	return 0;
}

// 获取农历年闰几月 (0表示无闰月)
function leapMonth(year) {
	return LUNAR_INFO[year - BASE_YEAR] & 0xf;
}

// 获取农历年某月的天数
function lunarMonthDays(year, month) {
	return (LUNAR_INFO[year - BASE_YEAR] & (0x10000 >> month)) ? 30 : 29;
}

// 公历转农历
function solarToLunar(year, month, day) {
	var date = new Date(year, month - 1, day);
	var offset = Math.floor((date - BASE_DATE) / 86400000);

	// 计算农历年
	var lunarYear, temp;
	for (lunarYear = BASE_YEAR; lunarYear < 2101 && offset > 0; lunarYear++) {
		temp = lunarYearDays(lunarYear);
		offset -= temp;
	}
	if (offset < 0) {
		offset += temp;
		lunarYear--;
	}

	// 计算农历月和日
	var lunarMonth, lunarDay;
	var leap = leapMonth(lunarYear);
	var isLeap = false;

	for (lunarMonth = 1; lunarMonth < 13 && offset > 0; lunarMonth++) {
		// 闰月
		if (leap > 0 && lunarMonth === (leap + 1) && !isLeap) {
			--lunarMonth;
			isLeap = true;
			temp = leapMonthDays(lunarYear);
		} else {
			temp = lunarMonthDays(lunarYear, lunarMonth);
		}

		if (isLeap && lunarMonth === (leap + 1))
			isLeap = false;

		offset -= temp;
	}

	if (offset === 0 && leap > 0 && lunarMonth === leap + 1) {
		if (isLeap) {
			isLeap = false;
		} else {
			isLeap = true;
			--lunarMonth;
		}
	}

	if (offset < 0) {
		offset += temp;
		--lunarMonth;
	}

	lunarDay = offset + 1;

	return {
		year: lunarYear,
		month: lunarMonth,
		day: lunarDay,
		isLeap: isLeap,
	};
}

// ========== 天干地支计算 ==========

// 年干支 (以立春为界)
function yearGanZhi(year) {
	var idx = (year - 4) % 60;
	return TIAN_GAN[idx % 10] + DI_ZHI[idx % 12];
}

// 月干支
function monthGanZhi(year, month) {
	// 月干 = (年干序号 * 2 + 月份) % 10
	var yearGanIdx = (year - 4) % 10;
	var ganIdx = (yearGanIdx * 2 + month) % 10;
	// 月支: 寅月(1月)开始
	var zhiIdx = (month + 1) % 12;
	return TIAN_GAN[ganIdx] + DI_ZHI[zhiIdx];
}

// 日干支 (基于儒略日)
function dayGanZhi(year, month, day) {
	// 使用高斯公式计算日干支
	var date = new Date(year, month - 1, day);
	// 以2000年1月7日(甲子日)为参考点
	var ref = new Date(2000, 0, 7);
	var diff = Math.floor((date - ref) / 86400000);
	var idx = ((diff % 60) + 60) % 60;
	return TIAN_GAN[idx % 10] + DI_ZHI[idx % 12];
}

// 获取日干支的地支序号
function dayZhiIndex(year, month, day) {
	var date = new Date(year, month - 1, day);
	var ref = new Date(2000, 0, 7);
	var diff = Math.floor((date - ref) / 86400000);
	var idx = ((diff % 60) + 60) % 60;
	return idx % 12;
}

// ========== 生肖 ==========
function getShengXiao(lunarYear) {
	return SHENG_XIAO[(lunarYear - 4) % 12];
}

// ========== 节气计算 ==========
// 使用寿星万年历算法计算节气日期
function solarTermDate(year, termIndex) {
	// termIndex: 0=小寒, 1=大寒, ..., 23=冬至
	var angle = TERM_ANGLES[termIndex];

	// 使用简化的VSOP87算法
	var y = year + (termIndex * 15.0 + 15.0) / 360.0;

	// 儒略世纪数 (J2000.0起算)
	var jdNew = 2451259.428 + 365.2422 * (y - 2000);

	// 太阳黄经修正
	var t = (jdNew - 2451545.0) / 36525.0;
	var l = 280.46646 + 36000.76983 * t + 0.0003032 * t * t;
	l = l % 360;
	if (l < 0) l += 360;

	// 迭代求解
	var targetAngle = angle;
	for (var i = 0; i < 10; i++) {
		var diff = targetAngle - l;
		if (diff > 180) diff -= 360;
		if (diff < -180) diff += 360;
		if (Math.abs(diff) < 0.0001) break;
		jdNew += diff / 360 * 365.2422;
		t = (jdNew - 2451545.0) / 36525.0;

		// 太阳平黄经
		var L0 = 280.46646 + 36000.76983 * t + 0.0003032 * t * t;
		// 太阳平近点角
		var M = 357.52911 + 35999.05029 * t - 0.0001537 * t * t;
		var Mrad = M * Math.PI / 180;
		// 太阳中心差
		var C = (1.914602 - 0.004817 * t - 0.000014 * t * t) * Math.sin(Mrad)
			+ (0.019993 - 0.000101 * t) * Math.sin(2 * Mrad)
			+ 0.000289 * Math.sin(3 * Mrad);
		l = (L0 + C) % 360;
		if (l < 0) l += 360;
	}

	// 儒略日转公历
	return jdToDate(jdNew);
}

function jdToDate(jd) {
	jd += 0.5;
	var z = Math.floor(jd);
	var f = jd - z;
	var a;
	if (z < 2299161) {
		a = z;
	} else {
		var alpha = Math.floor((z - 1867216.25) / 36524.25);
		a = z + 1 + alpha - Math.floor(alpha / 4);
	}
	var b = a + 1524;
	var c = Math.floor((b - 122.1) / 365.25);
	var d = Math.floor(365.25 * c);
	var e = Math.floor((b - d) / 30.6001);
	var day = b - d - Math.floor(30.6001 * e);
	var month = (e < 14) ? e - 1 : e - 13;
	var year = (month > 2) ? c - 4716 : c - 4715;
	return { year: year, month: month, day: day };
}

// 获取某天的节气名称 (如果当天是节气的话)
function getSolarTerm(year, month, day) {
	// 每月有两个节气, 检查当月对应的节气
	var startIdx = (month - 1) * 2;
	for (var i = startIdx; i < startIdx + 2 && i < 24; i++) {
		var termDate = solarTermDate(year, i);
		if (termDate.month === month && termDate.day === day)
			return SOLAR_TERMS[i];
	}
	return '';
}

// ========== 节日 ==========
function getHolidays(solarMonth, solarDay, lunarMonth, lunarDay, lunarIsLeap) {
	var holidays = [];

	// 公历节日
	var solarKey = '%02d%02d'.format(solarMonth, solarDay);
	if (SOLAR_HOLIDAYS[solarKey])
		holidays.push(SOLAR_HOLIDAYS[solarKey]);

	// 农历节日 (闰月不算)
	if (!lunarIsLeap) {
		var lunarKey = '%02d%02d'.format(lunarMonth, lunarDay);
		if (LUNAR_HOLIDAYS[lunarKey])
			holidays.push(LUNAR_HOLIDAYS[lunarKey]);

		// 除夕特殊处理: 如果腊月只有29天, 腊月廿九也是除夕
		if (lunarMonth === 12 && lunarDay === 29) {
			// 需要检查当年腊月是否只有29天
			// 简化处理: 如果没有三十, 廿九就是除夕
			if (!LUNAR_HOLIDAYS['1229'])
				holidays.push('除夕');
		}
	}

	return holidays;
}

// ========== 十二建星 (宜忌) ==========
function getJianXing(month, dayZhi) {
	// 十二建星: 以月建地支为"建", 依次排列
	// 正月建寅, 二月建卯, 三月建辰, ...
	var monthZhi = (month + 1) % 12; // 正月=寅(2)
	var idx = ((dayZhi - monthZhi) % 12 + 12) % 12;
	return JIAN_XING[idx];
}

// ========== 农历日期格式化 ==========
function formatLunarYear(year) {
	var s = '' + year;
	var result = '';
	for (var i = 0; i < s.length; i++)
		result += NONG_NIAN[parseInt(s[i])];
	return result;
}

function formatLunarMonth(month, isLeap) {
	return (isLeap ? '闰' : '') + NONG_YUE[month - 1] + '月';
}

function formatLunarDay(day) {
	return NONG_RI[day - 1];
}

// ========== LuCI 组件 ==========
return baseclass.extend({
	title: _('Chinese Calendar'),

	load: function() {
		return Promise.resolve(new Date());
	},

	render: function(date) {
		var year = date.getFullYear();
		var month = date.getMonth() + 1;
		var day = date.getDate();
		var data;

		try {
			var lunar = solarToLunar(year, month, day);
			var ganZhiYear = yearGanZhi(lunar.year);
			var ganZhiMonth = monthGanZhi(year, month);
			var ganZhiDay = dayGanZhi(year, month, day);
			var shengXiao = getShengXiao(lunar.year);
			var solarTerm = getSolarTerm(year, month, day);
			var holidays = getHolidays(month, day, lunar.month, lunar.day, lunar.isLeap);
			var dayZhi = dayZhiIndex(year, month, day);
			var jianXing = getJianXing(lunar.month, dayZhi);

			data = {
				lunar: '%s年 %s %s'.format(
					formatLunarYear(lunar.year),
					formatLunarMonth(lunar.month, lunar.isLeap),
					formatLunarDay(lunar.day)
				),
				ganzhi: '%s年 %s月 %s日'.format(ganZhiYear, ganZhiMonth, ganZhiDay),
				shengxiao: shengXiao,
				solar_term: solarTerm || '无',
				holiday: holidays.length > 0 ? holidays.join(' ') : '无',
				suitable: JIAN_YI[jianXing],
				avoidable: JIAN_JI[jianXing],
			};
		} catch (e) {
			data = {
				lunar: '?', ganzhi: '?', shengxiao: '?',
				solar_term: '?', holiday: '?',
				suitable: '?', avoidable: '?',
			};
		}

		var fields = [
			_('Lunar'),      data.lunar,
			_('GanZhi'),     data.ganzhi,
			_('Zodiac'),     data.shengxiao,
			_('Solar Term'), data.solar_term,
			_('Holiday'),    data.holiday,
			_('Suitable'),   data.suitable,
			_('Avoidable'),  data.avoidable,
		];

		var table = E('table', { 'class': 'table' });

		for (var i = 0; i < fields.length; i += 2) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [fields[i]]),
				E('td', { 'class': 'td left' }, [fields[i + 1] != null ? fields[i + 1] : '?'])
			]));
		}

		return table;
	},
});
