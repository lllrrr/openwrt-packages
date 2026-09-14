'use strict';
'require rpc';
'require uci';

var RE_TOML_TABLE     = /^\[([a-zA-Z_][a-zA-Z0-9_]*)\]$/;
var NO_COMMENT_FIELDS = ['white_list'];
var RAM_BASE_MB       = 128;

var callGetTheme = rpc.declare({ object:'luci.vnt2', method:'get_theme', params:[] });
var callSetTheme = rpc.declare({ object:'luci.vnt2', method:'set_theme', params:['theme'] });

var VNT2_ICON_PATHS = {
    start:   'M8 5v14l11-7z',
    stop:    'M6 6h12v12H6z',
    restart: 'M17.7 6.3A8 8 0 1 0 20 12h-2a6 6 0 1 1-1.76-4.24L13 11h8V3z',
    web:     'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm7.93 9h-3.02a15.6 15.6 0 0 0-1.2-5A8.03 8.03 0 0 1 19.93 11zM12 4.04c.83 1.2 1.48 3.12 1.72 5.96h-3.44C10.52 7.16 11.17 5.24 12 4.04zM4.07 13h3.02c.16 1.85.58 3.57 1.2 5a8.03 8.03 0 0 1-4.22-5zm3.02-2H4.07a8.03 8.03 0 0 1 4.22-5 15.6 15.6 0 0 0-1.2 5zM12 19.96c-.83-1.2-1.48-3.12-1.72-5.96h3.44c-.24 2.84-.89 4.76-1.72 5.96zM14 13h-4c-.03-.33-.04-.66-.04-1s.01-.67.04-1h4c.03.33.04.66.04 1s-.01.67-.04 1zm1.71 5c.62-1.43 1.04-3.15 1.2-5h3.02a8.03 8.03 0 0 1-4.22 5z',
    edit:    'M4 17.25V20h2.75L17.81 8.94l-2.75-2.75L4 17.25zM19.71 7.04a1 1 0 0 0 0-1.41l-1.34-1.34a1 1 0 0 0-1.41 0l-1.05 1.05 2.75 2.75 1.05-1.05z',
    delete:  'M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM8 4l1-1h6l1 1h4v2H4V4h4z',
    code:    'M8.7 16.3 4.4 12l4.3-4.3L7.3 6.3 1.6 12l5.7 5.7 1.4-1.4zm6.6 0 4.3-4.3-4.3-4.3 1.4-1.4 5.7 5.7-5.7 5.7-1.4-1.4zM13.3 4l-4 16h2.1l4-16h-2.1z',
    view:    'M12 5c5 0 9 4.5 10 7-1 2.5-5 7-10 7S3 14.5 2 12c1-2.5 5-7 10-7zm0 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8zm0 2a2 2 0 1 1 0 4 2 2 0 0 1 0-4z',
    copy:    'M8 8h11v13H8V8zm-3 8H3V3h13v2H5v11z',
    key:     'M6 6.5a5.5 5.5 0 1 0 0 11a5.5 5.5 0 1 0 0-11z M6 7.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 1 0 0-9z M11.5 10H21V14H19V17H16V14H11.5Z',
    sun:     'M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.8 1.42-1.42zM1 13h3v-2H1v2zm10-12v3h2V1h-2zm9.45 3.46l-1.41-1.41-1.8 1.79 1.42 1.42 1.79-1.8zM17.24 19.16l1.8 1.79 1.41-1.41-1.79-1.8-1.42 1.42zM20 11v2h3v-2h-3zM12 6a6 6 0 1 0 0 12A6 6 0 0 0 12 6zm-1 17h2v-3h-2v3zm-7.45-3.46l1.41 1.41 1.8-1.79-1.42-1.42-1.79 1.8z',
    moon:    'M21 14.6A8 8 0 0 1 9.4 3a7 7 0 1 0 11.6 11.6z'
};

function vnt2IconSvg(name) {
    var ns = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('class', 'vnt2-icon');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('width', '18');
    svg.setAttribute('height', '18');
    svg.setAttribute('aria-hidden', 'true');
    var path = document.createElementNS(ns, 'path');
    path.setAttribute('d', VNT2_ICON_PATHS[name] || VNT2_ICON_PATHS.start);
    svg.appendChild(path);
    return svg;
}

function detectLang() {
    var htmlLang = document.documentElement.lang || '';
    if (htmlLang && htmlLang !== 'auto') return htmlLang.toLowerCase();
    return (navigator.language || navigator.userLanguage || 'en').toLowerCase();
}

var VNT2Format = {
    detectLang: detectLang,

    stripAnsi: function(s) {
        return String(s || '').replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '');
    },

    bytes: function(b) {
        b = parseInt(b) || 0;
        if (b <= 0) return '0 B';
        var u = ['B', 'KB', 'MB', 'GB'], i = 0;
        while (b >= 1024 && i < 3) { b /= 1024; i++; }
        return b.toFixed(2) + ' ' + u[i];
    },

    uptime: function(s) {
        s = parseInt(s) || 0;
        if (s <= 0) return '-';
        var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
            m = Math.floor(s % 3600 / 60), parts = [];
        if (d > 0) parts.push(d + _('d'));
        if (h > 0) parts.push(h + _('h'));
        if (m > 0) parts.push(m + _('m'));
        parts.push(s % 60 + _('s'));
        return parts.join('');
    },

    memPercent: function(memMb) {
        return Math.min(100, (parseFloat(memMb) || 0) / RAM_BASE_MB * 100);
    }
};

var callGetWebAccess = rpc.declare({ object:'luci.vnt2', method:'get_web_access', params:[] });

var VNT2Web = {
    getAccess: function() {
        return callGetWebAccess().catch(function() { return {}; }).then(function(r) {
            r = r || {};
            return {
                addr:  r.addr  || '0.0.0.0:19099',
                token: r.token || ''
            };
        });
    },

    buildUrl: function(access, hash) {
        var addr  = (access && access.addr) || '0.0.0.0:19099';
        var token = (access && access.token) || '';
        var host  = addr.split(':')[0];
        var port  = addr.split(':').slice(1).join(':') || '19099';
        if (host === '0.0.0.0' || host === '127.0.0.1' || host === '::' || host === '[::]' || host === '')
            host = window.location.hostname;
        var url = window.location.protocol + '//' + host + ':' + port + '/';
        if (token) url += '?token=' + encodeURIComponent(token);
        if (hash) url += '#' + String(hash).replace(/^#/, '');
        return url;
    },

    open: function(hash) {
        return this.getAccess().then(function(access) {
            window.open(VNT2Web.buildUrl(access, hash), '_blank', 'noopener');
        });
    }
};

(function() {
    if (typeof document === 'undefined') return;
    var THEME_KEY = 'vnt2-theme';

    function savedTheme() {
        var v = '';
        try { v = window.localStorage.getItem(THEME_KEY) || ''; } catch(e) {}
        return (v === 'light' || v === 'dark') ? v : 'light';
    }

    function persistTheme(theme) {
        callSetTheme(theme).catch(function() {});
    }

    function syncThemeFromUci() {
        callGetTheme().then(function(r) {
            var t = (r && (r.theme === 'dark' || r.theme === 'light')) ? r.theme : 'light';
            try { window.localStorage.setItem(THEME_KEY, t); } catch(e) {}
            applyTheme(t);
        }).catch(function() {});
    }

    function applyTheme(theme) {
        document.documentElement.setAttribute('data-vnt2-theme', theme);
        var btn = document.getElementById('vnt2-theme-toggle');
        if (!btn) return;
        btn.innerHTML = '';
        btn.appendChild(vnt2IconSvg('sun'));
        btn.title = theme === 'dark' ? _('Dark theme') : _('Light theme');
    }

    applyTheme(savedTheme());
    syncThemeFromUci();

    if (!document.getElementById('vnt2-global-style')) {
        var link = document.createElement('link');
        link.id = 'vnt2-global-style';
        link.rel = 'stylesheet';
        link.href = (typeof L !== 'undefined' && L.resource)
            ? L.resource('vnt2/style.css')
            : '/luci-static/resources/vnt2/style.css';
        document.head.appendChild(link);
    }

    function vnt2Path() {
        var p = window.location.pathname || '';
        var m = p.match(/\/admin\/vpn\/vnt2(?:\/([^\/?#]+))?/);
        return m ? (m[1] || 'overview') : '';
    }

    function addTopNav(tries) {
        if (!vnt2Path()) return;
        if (document.getElementById('vnt2-global-nav')) return;
        var host = document.getElementById('maincontent') || document.querySelector('main') || document.querySelector('.main') || document.body;
        if (!host) {
            if ((tries || 0) < 20) window.setTimeout(function() { addTopNav((tries || 0) + 1); }, 80);
            return;
        }
        var nav = document.createElement('div');
        nav.id = 'vnt2-global-nav';
        nav.className = 'vnt2-global-nav';
        if (!document.getElementById('vnt2-theme-toggle')) {
            var btn = document.createElement('button');
            btn.id = 'vnt2-theme-toggle';
            btn.type = 'button';
            btn.className = 'vnt2-icon-btn vnt2-theme-toggle';
            btn.addEventListener('click', function(ev) {
                ev.preventDefault();
                var next = document.documentElement.getAttribute('data-vnt2-theme') === 'dark' ? 'light' : 'dark';
                try { window.localStorage.setItem(THEME_KEY, next); } catch(e) {}
                applyTheme(next);
                persistTheme(next);
            });
            nav.appendChild(btn);
        }
        if (host.firstChild) host.insertBefore(nav, host.firstChild);
        else host.appendChild(nav);
        applyTheme(document.documentElement.getAttribute('data-vnt2-theme') || savedTheme());
    }

    function markTabActive() {
        if (!vnt2Path()) return;
        var tabs = document.querySelector('#tabmenu ul.tabs');
        if (!tabs || !tabs.querySelectorAll) return;
        if (tabs.querySelector('li.active')) return;
        var want = '/' + vnt2Path();
        tabs.querySelectorAll('li').forEach(function(li) {
            var a = li.querySelector('a[href]');
            if (!a) return;
            var h = a.getAttribute('href') || '';
            if (h.slice(-want.length) === want) li.classList.add('active');
        });
    }

    function refreshChrome() {
        if (!vnt2Path()) {
            document.documentElement.removeAttribute('data-vnt2-theme');
            var staleNav = document.getElementById('vnt2-global-nav');
            if (staleNav && staleNav.parentNode) staleNav.parentNode.removeChild(staleNav);
            return;
        }
        if (!document.getElementById('vnt2-global-nav')) addTopNav(0);
        applyTheme(document.documentElement.getAttribute('data-vnt2-theme') || savedTheme());
        markTabActive();
    }

    function initTheme() {
        addTopNav(0);
        applyTheme(document.documentElement.getAttribute('data-vnt2-theme') || savedTheme());
        markTabActive();
        if (window.MutationObserver) {
            var MO = window.MutationObserver;
            var mc = document.getElementById('maincontent');
            if (mc) new MO(function() { refreshChrome(); }).observe(mc, { childList: true });
            var tb = document.getElementById('tabmenu');
            if (tb) new MO(function() { markTabActive(); }).observe(tb, { childList: true, subtree: true });
        }
        window.addEventListener('popstate', function() { refreshChrome(); });
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initTheme);
    else initTheme();
    window.setTimeout(addTopNav, 0);
})();

function escapeStr(s) {
    return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function findInComments(comments, re) {
    for (var i = 0; i < comments.length; i++) {
        var m = comments[i].match(re);
        if (m) return m;
    }
    return null;
}

function parseExtendMeta(comments) {
    var m = findInComments(comments || [], /(?:extend|扩展)[：:]\s*([A-Za-z0-9_.-]+)\s*=\s*text\(([^)]*)\)/i);
    if (!m) return null;
    var ext = { trigger:m[1], type:'text', prefix:'', placeholder:'' };
    m[2].split(',').forEach(function(part) {
        var i = part.indexOf('=');
        if (i <= 0) return;
        var k = part.substring(0, i).trim();
        var v = part.substring(i + 1).trim();
        if (k === 'prefix') ext.prefix = v;
        else if (k === 'placeholder') ext.placeholder = v;
    });
    return ext;
}

function isFieldTypeName(n) {
    return n === 'string' || n === 'array' || n === 'bool' || n === 'int' || n === 'select' || n === 'section';
}

function sectionInt(k, keyDefs) {
    var kd = keyDefs && keyDefs[k];
    return !!(kd && kd.type === 'int');
}

function writeSection(secVals, resultLines, secDef, keyDefs) {
    if (!secVals || typeof secVals !== 'object') return;
    Object.keys(secVals).forEach(function(k) {
        var v = secVals[k];
        if (Array.isArray(v)) {
            var items = v.filter(function(x) { return String(x).trim() !== ''; });
            resultLines.push(items.length
                ? k + ' = [' + items.map(function(x) {
                    return '"' + escapeStr(x) + '"';
                  }).join(', ') + ']'
                : k + ' = []');
        } else if (typeof v === 'boolean') {
            resultLines.push(k + ' = ' + (v ? 'true' : 'false'));
        } else if (v !== null && v !== undefined && String(v).trim()) {
            var sv = String(v).trim();
            if (sectionInt(k, keyDefs) && /^-?\d+$/.test(sv)) resultLines.push(k + ' = ' + sv);
            else resultLines.push(k + ' = "' + escapeStr(sv) + '"');
        } else if (secDef && secDef[k] !== undefined && secDef[k] !== '') {
            var dv = secDef[k];
            var ds = String(dv).trim();
            resultLines.push(
                typeof dv === 'boolean'
                    ? k + ' = ' + (dv ? 'true' : 'false')
                    : (sectionInt(k, keyDefs) && /^-?\d+$/.test(ds)
                        ? k + ' = ' + ds
                        : k + ' = "' + escapeStr(ds) + '"')
            );
        } else {
            var kdE = keyDefs && keyDefs[k];
            if (kdE && kdE.type === 'array') resultLines.push(k + ' = []');
            else resultLines.push('# ' + k + ' = ""');
        }
    });
}

function emptyField(key, suffix) {
    return (NO_COMMENT_FIELDS.indexOf(key) >= 0 ? '' : '# ') + key + ' = ' + suffix;
}

function buildSectionValues(secField, secVals) {
    var merged = {};
    Object.keys(secField.keys || {}).forEach(function(k) {
        merged[k] = (secVals && Object.prototype.hasOwnProperty.call(secVals, k))
            ? secVals[k] : secField['default'][k];
    });
    if (secVals) {
        Object.keys(secVals).forEach(function(k) {
            if (!Object.prototype.hasOwnProperty.call(merged, k))
                merged[k] = secVals[k];
        });
    }
    return merged;
}

var VNT2ConfigParser = {

    _extractI18nComment: function(lines) {
        if (typeof lines === 'string') {
            lines = lines.split(/\n|(?=\s[a-z]{2}(?:-[a-z]{2,4})?[：:])/i)
                .map(function(l) { return l.trim(); })
                .filter(Boolean);
        }
        var lang    = detectLang();
        var prefix  = lang.split('-')[0];
        var langMap = {};
        var generic = [];
        var reLang  = /^([a-z]{2}(?:-[a-z]{2,4})?)\s*[：:]\s*/i;

        lines.forEach(function(l) {
            var m = l.match(reLang);
            if (m) {
                var key = m[1].toLowerCase();
                langMap[key] = (langMap[key] ? langMap[key] + ' ' : '') +
                    l.substring(m[0].length).trim();
                } else if (!/^\[.*\]$/.test(l) && !/^(?:选项|options?|extend|扩展|示例|example)[：:]/i.test(l)) {
                    generic.push(l);
                }
        });

        return langMap[lang] || langMap[prefix] || langMap['en'] ||
            generic.join(' ') || '';
    },

    parseTemplate: function(content) {
        if (!content || typeof content !== 'string') return [];
        var lines          = content.split('\n');
        var fields         = [];
        var pendingComment = [];
        var currentSection = null;

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line) { pendingComment = []; continue; }

            if (line.charAt(0) === '#') {
                var commentText = line.substring(1).trim();
                if (/^[-=*\s]*$/.test(commentText)) { pendingComment = []; continue; }
                var ctC = commentText.match(RE_TOML_TABLE);
                if (ctC && !isFieldTypeName(ctC[1])) {
                    var tmS = findInComments(pendingComment, /\[(\w+)\]/);
                    if (tmS && tmS[1] === 'section') {
                        currentSection = {
                            name:      ctC[1],
                            type:      'section',
                            commented: true,
                            'default': {},
                            keys:      {},
                            comment:   this._extractI18nComment(pendingComment),
                            example:   (findInComments(pendingComment, /^(?:示例|example)[：:]\s*(.+)$/i) || [])[1] || '',
                            options:   []
                        };
                        fields.push(currentSection);
                        pendingComment = [];
                        continue;
                    }
                }
                if (currentSection && currentSection.commented) {
                    var keyC = commentText.match(/^([a-zA-Z_][A-Za-z0-9_.-]*)\s*=/);
                    if (keyC) {
                        var eqC  = commentText.indexOf('=');
                        var kC   = commentText.substring(0, eqC).trim();
                        var rawC = commentText.substring(eqC + 1).trim();
                        var tmC  = findInComments(pendingComment, /\[(\w+)\]/);
                        var ftC  = tmC ? tmC[1] : this._inferType(rawC);
                        var optC = [];
                        var omC  = findInComments(pendingComment, /(?:选项|options?)[：:]\s*(.+)/i);
                        if (omC) {
                            var osC = omC[1].trim();
                            optC = (osC.indexOf(',') !== -1)
                                ? osC.split(',').map(function(x) { return x.trim(); }).filter(Boolean)
                                : osC.split(/\s+/).filter(Boolean);
                        }
                        var exC = findInComments(pendingComment, /示例[：:]\s*(?:\w+\s*=\s*)?(\S+)/);
                        var pdC = this._parseValue(rawC, ftC);
                        currentSection.keys[kC] = {
                            type:      ftC,
                            'default': pdC,
                            comment:   this._extractI18nComment(pendingComment),
                            example:   exC ? exC[1] : '',
                            options:   optC,
                            extend:    parseExtendMeta(pendingComment)
                        };
                        if (rawC !== '' && ftC !== 'array') {
                            currentSection['default'][kC] =
                                ftC === 'bool' ? pdC : String(pdC).replace(/^["']|["']$/g, '');
                        }
                        pendingComment = [];
                        continue;
                    }
                }
                pendingComment.push(commentText);
                continue;
            }

            var tblMatch = line.match(RE_TOML_TABLE);
            if (tblMatch) {
                var typeM = findInComments(pendingComment, /\[(\w+)\]/);
                if (typeM && typeM[1] === 'section') {
                    currentSection = {
                        name:      tblMatch[1],
                        type:      'section',
                        'default': {},
                        keys:      {},
                        comment:   this._extractI18nComment(pendingComment),
                        example:   (findInComments(pendingComment, /^(?:示例|example)[：:]\s*(.+)$/i) || [])[1] || '',
                        options:   []
                    };
                    fields.push(currentSection);
                } else {
                    currentSection = null;
                }
                pendingComment = [];
                continue;
            }

            if (currentSection && currentSection.commented) currentSection = null;

            var eqIdx = line.indexOf('=');
            if (eqIdx < 0) { pendingComment = []; continue; }

            var key    = line.substring(0, eqIdx).trim();
            var rawVal = line.substring(eqIdx + 1).trim();
            var typeM2    = findInComments(pendingComment, /\[(\w+)\]/);
            var fieldType = typeM2 ? typeM2[1] : this._inferType(rawVal);
            var options = [];
            var optM    = findInComments(pendingComment, /(?:选项|options?)[：:]\s*(.+)/i);
            if (optM) {
                var optStr = optM[1].trim();
                options = (optStr.indexOf(',') !== -1)
                    ? optStr.split(',').map(function(s) { return s.trim(); }).filter(Boolean)
                    : optStr.split(/\s+/).filter(Boolean);
            }

            var exM     = findInComments(pendingComment, /示例[：:]\s*(?:\w+\s*=\s*)?(\S+)/);
            var example = exM ? exM[1] : '';
            var extend = parseExtendMeta(pendingComment);

            var comment = this._extractI18nComment(pendingComment);
            if (currentSection) {
                var parsedDefault = this._parseValue(rawVal, fieldType);
                currentSection.keys[key] = {
                    type:      fieldType,
                    'default': parsedDefault,
                    comment:   comment,
                    example:   example,
                    options:   options,
                    extend:    extend
                };
                if (rawVal !== '' && fieldType !== 'array') {
                    currentSection['default'][key] =
                        fieldType === 'bool' ? parsedDefault
                        : String(parsedDefault).replace(/^["']|["']$/g, '');
                }
            } else {
                fields.push({
                    name:      key,
                    type:      fieldType,
                    'default': this._parseValue(rawVal, fieldType),
                    comment:   comment,
                    example:   example,
                    options:   options,
                    extend:    extend
                });
            }
            pendingComment = [];
        }
        return fields;
    },

    parseValues: function(content) {
        if (!content || typeof content !== 'string') return {};
        var values           = {};
        var currentSection   = null;
        var sectionCommented = false;

        content.split('\n').forEach(function(line) {
            var trimmed = line.trim();
            if (!trimmed) return;

            var isComment = trimmed.charAt(0) === '#';
            var checkLine = isComment ? trimmed.substring(1).trim() : trimmed;
            if (!checkLine) return;

            var tblMatch = checkLine.match(RE_TOML_TABLE);
            if (tblMatch && !isFieldTypeName(tblMatch[1])) {
                currentSection   = tblMatch[1];
                sectionCommented = isComment;
                if (!values[currentSection]) values[currentSection] = {};
                return;
            }

            var eqIdx = checkLine.indexOf('=');
            if (eqIdx < 0) return;
            if (currentSection && isComment && !sectionCommented) return;
            var key = checkLine.substring(0, eqIdx).trim();
            if (!/^[a-zA-Z_][a-zA-Z0-9_.-]*$/.test(key)) return;
            var val = checkLine.substring(eqIdx + 1).trim();
            if (isComment) val = val.replace(/\s+#.*$/, '');

            if (currentSection) {
                if (val.charAt(0) === '[') {
                    values[currentSection][key] =
                        VNT2ConfigParser._parseArray(val);
                    return;
                }
                var bare = val.replace(/^["']|["']$/g, '');
                values[currentSection][key] =
                    (bare === 'true' || bare === 'false') ? (bare === 'true') : bare;
            } else {
                values[key] = VNT2ConfigParser._parseRawValue(val);
            }
        });
        return values;
    },

    serializeToToml: function(fields, values, templateContent) {
        if (!templateContent) return '';
        var resultLines    = [];
        var typeMap        = {};
        var currentSection = null;
        var sectionEmitted = false;
        var skipSection    = null;

        fields.forEach(function(f) { typeMap[f.name] = f; });

        function emitSectionBlock(name) {
            var secField = typeMap[name];
            var vals = secField
                ? buildSectionValues(secField, values[name])
                : (values[name] || {});
            var enabled = !!(vals && (vals.enabled === true || vals.enabled === 'true'));
            if (secField && secField.commented && !enabled) {
                resultLines.push('# [' + name + ']');
                var body = [];
                writeSection(vals, body, secField['default'], secField.keys);
                body.forEach(function(l) { resultLines.push(l.charAt(0) === '#' ? l : '# ' + l); });
            } else {
                resultLines.push('[' + name + ']');
                if (secField) writeSection(vals, resultLines, secField['default'], secField.keys);
                else writeSection(vals, resultLines);
            }
        }

        function blockMember(trimmed) {
            if (trimmed.charAt(0) !== '#') return false;
            var text = trimmed.substring(1).trim();
            if (!text) return true;
            if (/^\[(string|array|bool|int|select)\]$/.test(text)) return true;
            if (/^(zh-cn|en)\s*[：:]/i.test(text)) return true;
            if (/^示例\s*[：:]/.test(text)) return true;
            if (/^(options?|选项)\s*[：:]/i.test(text)) return true;
            if (/^extend\s*[：:]/i.test(text)) return true;
            var km = text.match(/^([a-zA-Z_][A-Za-z0-9_.-]*)\s*=/);
            return !!(km && skipSection && skipSection.keys &&
                Object.prototype.hasOwnProperty.call(skipSection.keys, km[1]));
        }

        templateContent.split('\n').forEach(function(line) {
            var trimmed = line.trim();

            if (skipSection) {
                if (blockMember(trimmed)) return;
                skipSection = null;
            }

            if (!trimmed) {
                if (currentSection === null) resultLines.push('');
                return;
            }

            var tblMatch = trimmed.match(RE_TOML_TABLE);
            if (tblMatch) {
                if (currentSection !== null) resultLines.push('');
                currentSection = tblMatch[1];
                sectionEmitted = false;
                emitSectionBlock(currentSection);
                sectionEmitted = true;
                return;
            }

            if (trimmed.charAt(0) === '#') {
                var cText = trimmed.substring(1).trim();
                var cTbl = cText.match(RE_TOML_TABLE);
                if (cTbl && typeMap[cTbl[1]] && typeMap[cTbl[1]].type === 'section' && typeMap[cTbl[1]].commented) {
                    if (currentSection !== null) resultLines.push('');
                    currentSection = null;
                    emitSectionBlock(cTbl[1]);
                    skipSection = typeMap[cTbl[1]];
                    return;
                }
            }

            if (currentSection !== null) {
                if (trimmed.charAt(0) === '#') resultLines.push(line);
                return;
            }
            if (!/^[a-zA-Z_][a-zA-Z0-9_.-]*\s*=/.test(trimmed) &&
                !/^\[/.test(trimmed)) {
                resultLines.push(trimmed.charAt(0) === '#' ? line : '# ' + line);
                return;
            }

            var checkLine = trimmed;
            if (trimmed.charAt(0) === '#') checkLine = trimmed.substring(1).trim();
            var eqIdx = checkLine.indexOf('=');
            if (eqIdx < 0) { resultLines.push(line); return; }
            var key = checkLine.substring(0, eqIdx).trim();

            resultLines.push(
                Object.prototype.hasOwnProperty.call(values, key)
                    ? VNT2ConfigParser._formatField(key, values[key], typeMap[key])
                    : line
            );
        });

        if (currentSection !== null && !sectionEmitted) emitSectionBlock(currentSection);

        return resultLines.join('\n');
    },

    _isEmptyValue: function(value, field) {
        if (value == null) return true;
        if (Array.isArray(value)) return value.filter(function(v) { return String(v).trim() !== ''; }).length === 0;
        if (typeof value === 'boolean') return value === false;
        if (typeof value === 'number') {
            var def = field ? field['default'] : null;
            return def != null && parseInt(value) === (parseInt(def) || 0);
        }
        if (typeof value === 'string') return value.trim() === '';
        if (typeof value === 'object') {
            var keys = Object.keys(value);
            for (var i = 0; i < keys.length; i++)
                if (!this._isEmptyValue(value[keys[i]], field && field.keys ? field.keys[keys[i]] : null)) return false;
            return true;
        }
        return false;
    },

    _hasSavableDefault: function(field) {
        if (!field || !Object.prototype.hasOwnProperty.call(field, 'default')) return false;
        var def = field['default'];
        if (def == null) return false;
        if (Array.isArray(def)) return def.length > 0;
        if (typeof def === 'boolean') return true;
        if (field.type === 'int' || typeof def === 'number') return true;
        if (typeof def === 'string') return def.trim() !== '';
        if (typeof def === 'object') return Object.keys(def).length > 0;
        return false;
    },

    _shouldEmitField: function(field, value) {
        if (!field) return !this._isEmptyValue(value, field);
        var required = field.comment && field.comment.indexOf('必填') !== -1;
        if (field.type === 'array' || Array.isArray(value))
            return Array.isArray(value) && value.length > 0;
        if (field.type === 'section') return !this._isEmptyValue(value, field);
        if (field.type === 'bool' || typeof value === 'boolean')
            return this._hasSavableDefault(field) || value === true;
        if (field.type === 'int' || typeof value === 'number') {
            if (value == null || value === '') return false;
            return this._hasSavableDefault(field) || required || (parseInt(value) || 0) !== 0;
        }
        if (typeof value === 'string')
            return value.trim() !== '';
        return !this._isEmptyValue(value, field);
    },

    _formatSparseSection: function(secField, secVals) {
        var out = [];
        if (!secField || !secVals) return out;
        var keys = Object.keys(secField.keys || {});
        for (var i = 0; i < keys.length; i++) {
            var k = keys[i], def = secField.keys[k];
            if (!Object.prototype.hasOwnProperty.call(secVals, k)) continue;
            var v = secVals[k];
            if (!this._shouldEmitField(def, v)) continue;
            out.push(this._formatField(k, v, def));
        }
        return out;
    },

    serializeSparseToToml: function(fields, values) {
        var result = [];
        fields = fields || [];
        values = values || {};
        for (var i = 0; i < fields.length; i++) {
            var f = fields[i];
            if (!Object.prototype.hasOwnProperty.call(values, f.name)) continue;
            var v = values[f.name];
            if (f.type === 'section') {

                if (f.name === 'ikev2' && (!v || v.enabled !== true)) {
                    result.push('[ikev2]');
                    result.push('enabled = false');
                    result.push('');
                    continue;
                }
                var lines = this._formatSparseSection(f, v);
                if (!lines.length) continue;
                result.push('[' + f.name + ']');
                Array.prototype.push.apply(result, lines);
                result.push('');
            } else {
                if (!this._shouldEmitField(f, v)) continue;
                result.push(this._formatField(f.name, v, f));
            }
        }
        while (result.length && result[result.length - 1] === '') result.pop();
        return result.join('\n') + (result.length ? '\n' : '');
    },

    hasWebAddr: function(content) {
        if (!content || typeof content !== 'string') return false;
        var v = this.parseValues(content)['web_addr'];
        return typeof v === 'string' && v.trim() !== '';
    },

    _formatField: function(key, value, type) {
        if (type === 'array' || Array.isArray(value)) {
            var arr = Array.isArray(value) ? value : [];
            if (!arr.length) return emptyField(key, '[]');
            return key + ' = [' + arr.map(function(v) {
                return '"' + escapeStr(v) + '"';
            }).join(', ') + ']';
        }
        if (type === 'bool' || typeof value === 'boolean')
            return key + ' = ' + (value ? 'true' : 'false');
        if (type === 'int' || typeof value === 'number')
            return key + ' = ' + (parseInt(value) || 0);
        if (typeof value === 'string')
            return value.trim()
                ? key + ' = "' + escapeStr(value) + '"'
                : emptyField(key, '""');
        return key + ' = ' + String(value);
    },

    _inferType: function(rawVal) {
        if (rawVal === 'true' || rawVal === 'false') return 'bool';
        if (rawVal.charAt(0) === '[')               return 'array';
        if (/^\d+$/.test(rawVal))                   return 'int';
        return 'string';
    },

    _parseValue: function(rawVal, type) {
        if (type === 'bool')  return rawVal === 'true';
        if (type === 'int')   return parseInt(rawVal) || 0;
        if (type === 'array') return this._parseArray(rawVal);
        return rawVal.replace(/^["']|["']$/g, '');
    },

    _parseRawValue: function(rawVal) {
        return this._parseValue(rawVal, this._inferType(rawVal));
    },

    _parseArray: function(rawVal) {
        var inner = rawVal.replace(/^\s*\[\s*|\s*\]\s*$/g, '');
        if (!inner.trim()) return [];
        var results = [], re = /"([^"]*)"|'([^']*)'/g, m;
        while ((m = re.exec(inner)) !== null)
            results.push(m[1] !== undefined ? m[1] : m[2]);
        return results.length ? results
            : inner.split(',').map(function(s) { return s.trim(); }).filter(Boolean);
    }
};

var VNT2_EVENT_TEXT = {
    checking_version:      function(a) { return _('Checking version: %s').format(a.project || ''); },
    version_list_ready:    function(a) { return _('Found %s versions').format(a.count || ''); },
    download_prepare:      function()  { return _('Preparing to download...'); },
    download_complete:     function(a) { return _('Download complete: %s').format(a.file || ''); },
    installation_started:  function()  { return _('Starting installation...'); },
    installation_complete: function(a) { return _('Installation complete: %s').format(a.installed || ''); },
    checksum_passed:       function()  { return _('SHA256 verification passed'); },
    checksum_failed:       function()  { return _('SHA256 verification failed, please re-download'); },
    download_failed:       function()  { return _('Download failed'); },
    api_request_failed:    function()  { return _('API request failed, please switch mirror'); },
    no_matching_file:      function()  { return _('No matching file found, please switch mirror'); }
};

var VNT2Events = {
    text: function(code, args) {
        var fn = VNT2_EVENT_TEXT[code];
        return fn ? fn(args || {}) : (code || '');
    },
    line: function(line) {
        var m = String(line || '').match(/(?:^|\s)EVENT\s+([A-Za-z0-9_]+)(?:\s+(.*))?$/);
        if (!m) return null;
        var args = {};
        (m[2] || '').split(/\s+/).forEach(function(part) {
            var i = part.indexOf('=');
            if (i > 0) args[part.substring(0, i)] = part.substring(i + 1);
        });
        return VNT2Events.text(m[1], args);
    }
};

var VNT2Validation = {
    collectConfigKeys: function(text, includeCommented) {
        var keys = {}, list = [], section = '';
        String(text || '').split('\n').forEach(function(line) {
            var trimmed = line.trim();
            var sm = trimmed.match(/^#?\s*\[([A-Za-z_][A-Za-z0-9_]*)\]$/);
            if (sm) { if (!isFieldTypeName(sm[1])) section = sm[1]; return; }
            var re = includeCommented
                ? /^\s*#?\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*=/
                : /^\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*=/;
            var m = line.match(re);
            if (!m) return;
            var key = section ? section + '.' + m[1] : m[1];
            if (!keys[key]) list.push(key);
            keys[key] = true;
        });
        return { keys:keys, list:list };
    },

    validateDuplicateParameters: function(content, includeCommented) {
        var seen = {}, section = '', errors = [];
        String(content || '').split('\n').forEach(function(line) {
            var trimmed = line.trim();
            var sm = trimmed.match(/^#?\s*\[([A-Za-z_][A-Za-z0-9_]*)\]$/);
            if (sm) { if (!isFieldTypeName(sm[1])) section = sm[1]; return; }
            var re = includeCommented
                ? /^\s*#?\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*=/
                : /^\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*=/;
            var m = line.match(re);
            if (!m) return;
            var key = section ? section + '.' + m[1] : m[1];
            if (seen[key]) errors.push(_('Duplicate parameter: %s').format(key));
            seen[key] = true;
        });
        return errors;
    },

    unknownAgainstReference: function(content, referenceText, includeCommented) {
        var cur = this.collectConfigKeys(content, !!includeCommented);
        var ref = this.collectConfigKeys(referenceText, true);
        var missing = [];
        cur.list.forEach(function(k) { if (!ref.keys[k]) missing.push(k); });
        return missing;
    },

    unknownParamsMessage: function(keys) {
        return _('Not found in official --conf-example: %s. Save anyway?')
            .format((keys || []).join(', '));
    }
};

function meterLevel(percent, mode) {
    if (mode === 'green') return 'vnt2-meter-green';
    if (percent >= 85) return 'vnt2-meter-danger';
    if (percent >= 60) return 'vnt2-meter-warn';
    return 'vnt2-meter-ok';
}

var METER_LEVELS = ['vnt2-meter-green', 'vnt2-meter-ok', 'vnt2-meter-warn', 'vnt2-meter-danger'];

var VNT2UI = {

    notify: function(msg, type) {
        var el = E('div', {
            'class': 'vnt2-toast vnt2-toast-' + (type || 'info'),
            'click': function() { if (el.parentNode) el.parentNode.removeChild(el); }
        }, msg);
        document.body.appendChild(el);
        window.setTimeout(function() {
            if (el.parentNode) el.parentNode.removeChild(el);
        }, 5000);
    },

    confirm: function(title, msg) {
        return new Promise(function(resolve) {
            var overlay = E('div', {'class':'vnt2-modal-overlay'});
            var onKey = function(ev) {
                if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); done(false); }
                else if (ev.key === 'Enter') { ev.preventDefault(); ev.stopPropagation(); done(true); }
            };
            var done = function(val) {
                document.removeEventListener('keydown', onKey, true);
                if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
                resolve(val);
            };
            var modal = E('div', {'class':'vnt2-modal'}, [
                E('div', {'class':'vnt2-modal-title'}, title == null ? '' : String(title)),
                E('div', {'class':'vnt2-modal-msg'}, msg == null ? '' : String(msg)),
                E('div', {'class':'vnt2-modal-btns'}, [
                    E('button', {
                        'class':'btn',
                        'click': function() { done(false); }
                    }, _('Cancel')),
                    E('button', {
                        'class':'btn cbi-button-action important',
                        'click': function() { done(true); }
                    }, _('Confirm'))
                ])
            ]);
            overlay.appendChild(modal);
            overlay.addEventListener('click', function(ev) {
                if (ev.target === overlay) done(false);
            });
            document.addEventListener('keydown', onKey, true);
            document.body.appendChild(overlay);
            var primary = modal.querySelector('.cbi-button-action');
            if (primary) primary.focus();
        });
    },

    modal: function(title, nodes, extraClass) {
        var overlay = E('div', {'class':'vnt2-modal-overlay'});
        var onKey = function(ev) {
            if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); close(); }
        };
        var close = function() {
            document.removeEventListener('keydown', onKey, true);
            if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
        };
        var modal = E('div', {'class':'vnt2-modal' + (extraClass ? ' ' + extraClass : '')}, [
            E('div', {'class':'vnt2-modal-title'}, title == null ? '' : String(title))
        ].concat(nodes || []));
        overlay.appendChild(modal);
        overlay.addEventListener('click', function(ev) {
            if (ev.target === overlay) close();
        });
        document.addEventListener('keydown', onKey, true);
        document.body.appendChild(overlay);
        return close;
    },

    statusBadge: function(running) {
        var cls = running === undefined || running === null
            ? 'vnt2-badge-disabled' : (running ? 'vnt2-badge-running' : 'vnt2-badge-stopped');
        var txt = running === undefined || running === null
            ? _('Disabled') : (running ? _('Running') : _('Stopped'));
        return E('span', {'class':'vnt2-status-badge ' + cls}, txt);
    },

    card: function(title, content, extraClass) {
        return E('div', {'class':'vnt2-card ' + (extraClass || '')}, [
            title ? E('div', {'class':'vnt2-card-title'}, title) : E('span', {}),
            E('div', {'class':'vnt2-card-body'}, Array.isArray(content) ? content : [content])
        ]);
    },

    toggleSwitch: function(id, checked, onChange, label, disabled) {
        var cb = E('input', {
            'type':'checkbox',
            'class':'vnt2-toggle-input',
            'id': id || null
        });
        if (checked) cb.setAttribute('checked', 'checked');
        if (disabled) cb.setAttribute('disabled', 'disabled');
        if (onChange) cb.addEventListener('change', function(ev) { if (!disabled) onChange(ev, cb); });
        return E('label', {'class':'vnt2-toggle-wrap' + (disabled ? ' vnt2-toggle-disabled' : '')}, [
            cb,
            E('span', {'class':'vnt2-toggle-slider'}),
            label ? E('span', {'class':'vnt2-toggle-text'}, label) : E('span', {})
        ]);
    },

    iconSvg: function(name) {
        return vnt2IconSvg(name);
    },

    iconButton: function(action, title, onClick, disabled) {
        return E('button', {
            'type':'button',
            'class':'vnt2-icon-btn vnt2-icon-' + action + (disabled ? ' is-disabled' : ''),
            'title': title,
            'disabled': disabled ? 'disabled' : null,
            'click': function(ev) { ev.preventDefault(); if (!disabled && onClick) onClick(ev); }
        }, [this.iconSvg(action), E('span', {'class':'vnt2-icon-btn-text'}, title)]);
    },

    progressBar: function(percent, text, cls, mode) {
        percent = Math.max(0, Math.min(100, parseFloat(percent) || 0));
        return E('div', {'class':'vnt2-meter ' + meterLevel(percent, mode) + ' ' + (cls || '')}, [
            E('div', {'class':'vnt2-meter-head'}, [
                E('span', {}, text || ''),
                E('b', {}, percent.toFixed(1) + '%')
            ]),
            E('div', {'class':'vnt2-meter-track'},
                E('div', {'class':'vnt2-meter-fill', 'style':'width:' + percent + '%;'})
            )
        ]);
    },

    updateProgressBar: function(meter, percent, text, mode) {
        if (!meter) return;
        percent = Math.max(0, Math.min(100, parseFloat(percent) || 0));
        meter.classList.remove.apply(meter.classList, METER_LEVELS);
        meter.classList.add(meterLevel(percent, mode));
        var label = meter.querySelector('.vnt2-meter-head span');
        var num   = meter.querySelector('.vnt2-meter-head b');
        var fill  = meter.querySelector('.vnt2-meter-fill');
        if (label && text != null) label.textContent = text;
        if (num) num.textContent = percent.toFixed(1) + '%';
        if (fill) window.requestAnimationFrame(function() { fill.style.width = percent + '%'; });
    },

    resourceBars: function(cpu, memMb) {
        var mem = parseFloat(memMb) || 0;
        return E('div', {'class':'vnt2-resource-bars'}, [
            this.progressBar(cpu || 0, 'CPU', 'vnt2-meter-cpu'),
            this.progressBar(VNT2Format.memPercent(mem), 'RAM ' + mem.toFixed(1) + 'M', 'vnt2-meter-mem')
        ]);
    },

    updateResourceBars: function(el, cpu, memMb) {
        if (!el) return;
        var mem = parseFloat(memMb) || 0;
        var memPercent = VNT2Format.memPercent(mem);
        if (!el.querySelector('.vnt2-resource-bars')) {
            el.innerHTML = '';
            el.appendChild(this.resourceBars(0, mem));
        }
        var meters = el.querySelectorAll('.vnt2-meter');
        if (meters[0] && cpu != null) this.updateProgressBar(meters[0], cpu, 'CPU');
        if (meters[1]) this.updateProgressBar(meters[1], memPercent, 'RAM ' + mem.toFixed(1) + 'M');
    },

    buildFormRow: function(label, inputEl, desc) {
        return E('div', {'class':'vnt2-form-row'}, [
            E('div', {'class':'vnt2-form-label'}, label),
            E('div', {'class':'vnt2-form-control'}, [
                inputEl,
                desc ? E('div', {'class':'vnt2-form-desc'}, desc) : E('span', {})
            ])
        ]);
    }
};

return L.Class.extend({
    VNT2ConfigParser: VNT2ConfigParser,
    VNT2UI:           VNT2UI,
    VNT2Events:       VNT2Events,
    VNT2Validation:   VNT2Validation,
    VNT2Format:       VNT2Format,
    VNT2Web:          VNT2Web
});

