'use strict';

var RE_TOML_TABLE    = /^\[([a-zA-Z_][a-zA-Z0-9_]*)\]$/;
var NO_COMMENT_FIELDS = ['white_list'];

function detectLang() {
    var htmlLang = document.documentElement.lang || '';
    if (htmlLang && htmlLang !== 'auto') return htmlLang.toLowerCase();
    return (navigator.language || navigator.userLanguage || 'en').toLowerCase();
}

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


function writeSection(secVals, resultLines, secDef) {
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
        } else if (v && String(v).trim()) {
            resultLines.push(k + ' = "' + escapeStr(String(v)) + '"');
        } else if (secDef && secDef[k] !== undefined && secDef[k] !== '') {
            var dv = secDef[k];
            resultLines.push(
                typeof dv === 'boolean'
                    ? k + ' = ' + (dv ? 'true' : 'false')
                    : k + ' = "' + escapeStr(String(dv)) + '"'
            );
        } else {
            resultLines.push('# ' + k + ' = ""');
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
            } else if (!/^\[.*\]$/.test(l) && !/^(?:选项|options?)[：:]/i.test(l)) {
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
                        options:   []
                    };
                    fields.push(currentSection);
                } else {
                    currentSection = null;
                }
                pendingComment = [];
                continue;
            }

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

            var comment = this._extractI18nComment(pendingComment);
            if (currentSection) {
                var parsedDefault = this._parseValue(rawVal, fieldType);
                currentSection.keys[key] = {
                    type:      fieldType,
                    'default': parsedDefault,
                    comment:   comment,
                    example:   example,
                    options:   options
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
                    options:   options
                });
            }
            pendingComment = [];
        }
        return fields;
    },

    parseValues: function(content) {
        if (!content || typeof content !== 'string') return {};
        var values         = {};
        var currentSection = null;

        content.split('\n').forEach(function(line) {
            var trimmed = line.trim();
            if (!trimmed) return;

            var isComment = trimmed.charAt(0) === '#';
            if (isComment && currentSection) return;

            var checkLine = trimmed;
            if (isComment) {
                checkLine = trimmed.substring(1).trim();
                if (!checkLine || checkLine.indexOf('=') < 0) return;
            }

            var tblMatch = checkLine.match(RE_TOML_TABLE);
            if (tblMatch) {
                currentSection = tblMatch[1];
                if (!values[currentSection]) values[currentSection] = {};
                return;
            }

            var eqIdx = checkLine.indexOf('=');
            if (eqIdx < 0) return;
            var key = checkLine.substring(0, eqIdx).trim();
            var val = checkLine.substring(eqIdx + 1).trim();

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

    _sectionValToText: function(key, rawVal, type) {
        if (type === 'bool' || rawVal === 'true' || rawVal === 'false')
            return rawVal === 'true' ? 'true' : 'false';
        return rawVal.replace(/^["']|["']$/g, '');
    },

    serializeToToml: function(fields, values, templateContent) {
        if (!templateContent) return '';
        var resultLines    = [];
        var typeMap        = {};
        var currentSection = null;
        var sectionEmitted = false;

        fields.forEach(function(f) { typeMap[f.name] = f; });

        function emitSectionBody(name) {
            var secField = typeMap[name];
            if (secField && secField.type === 'section') {
                writeSection(buildSectionValues(secField, values[name]),
                    resultLines, secField['default']);
            } else {
                writeSection(values[name], resultLines);
            }
        }

        templateContent.split('\n').forEach(function(line) {
            var trimmed = line.trim();
            if (!trimmed) {
                if (currentSection === null) resultLines.push('');
                return;
            }

            var tblMatch = trimmed.match(RE_TOML_TABLE);
            if (tblMatch) {
                if (currentSection !== null) resultLines.push('');
                currentSection = tblMatch[1];
                sectionEmitted = false;
                resultLines.push(line);
                emitSectionBody(currentSection);
                sectionEmitted = true;
                return;
            }
            if (currentSection !== null) return;
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

        if (currentSection !== null && !sectionEmitted) emitSectionBody(currentSection);

        return resultLines.join('\n');
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

var VNT2Events = {
    text: function(code, args) {
        args = args || {};
        var map = {
            checking_version: _('Checking version: %s').format(args.project || ''),
            version_list_ready: _('Found %s versions').format(args.count || ''),
            download_prepare: _('Preparing to download...'),
            download_complete: _('Download complete: %s').format(args.file || ''),
            installation_started: _('Starting installation...'),
            installation_complete: _('Installation complete: %s').format(args.installed || ''),
            checksum_passed: _('SHA256 verification passed'),
            checksum_failed: _('SHA256 verification failed, please re-download'),
            download_failed: _('Download failed'),
            api_request_failed: _('API request failed, please switch mirror'),
            no_matching_file: _('No matching file found, please switch mirror'),
            download_failed: _('Download failed')
        };
        return map[code] || code || '';
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

var VNT2UI = {

    notify: function(msg, type) {
        var bg = {success:'#28a745', error:'#dc3545', info:'#17a2b8'}[type] || '#17a2b8';
        var el = E('div', {
            'style': [
                'position:fixed','top:60px','right:20px','z-index:9999',
                'padding:10px 20px','border-radius:4px','background:'+bg,
                'color:#fff','font-size:14px','box-shadow:0 2px 8px rgba(0,0,0,.3)',
                'max-width:400px','word-break:break-all','cursor:pointer'
            ].join(';'),
            'click': function() { if (el.parentNode) el.parentNode.removeChild(el); }
        }, msg);
        document.body.appendChild(el);
        window.setTimeout(function() {
            if (el.parentNode) el.parentNode.removeChild(el);
        }, 5000);
    },

    confirm: function(title, msg) {
        return new Promise(function(resolve) {
            L.ui.showModal(title, [
                E('p', {}, msg),
                E('div', {'class':'right','style':'margin-top:12px;'}, [
                    E('button', {
                        'class':'btn','style':'margin-right:8px;',
                        'click': function() { L.ui.hideModal(); resolve(false); }
                    }, _('Cancel')),
                    E('button', {
                        'class':'btn cbi-button-action important',
                        'click': function() { L.ui.hideModal(); resolve(true); }
                    }, _('Confirm'))
                ])
            ]);
        });
    },

    statusBadge: function(running) {
        if (running === undefined || running === null)
            return E('span', {'style':'color:#999;font-size:13px;'}, _('Disabled'));
        return E('span', {
            'style': 'color:'+(running?'#28a745':'#dc3545')+
                     ';font-weight:bold;font-size:13px;'
        }, running ? _('✓ Running') : _('✗ Not running'));
    },

    buildFormRow: function(label, inputEl, desc) {
        return E('div', {
            'style': 'display:flex;align-items:flex-start;padding:10px 0;border-bottom:1px solid #f0f0f0;'
        }, [
            E('div', {'style':'width:220px;font-weight:bold;padding-top:4px;flex-shrink:0;'}, label),
            E('div', {'style':'flex:1;'}, [
                inputEl,
                desc ? E('div', {'style':'color:#888;font-size:12px;margin-top:4px;'}, desc)
                     : E('span', {})
            ])
        ]);
    }
};

return L.Class.extend({
    VNT2ConfigParser: VNT2ConfigParser,
    VNT2UI:           VNT2UI,
    VNT2Events:       VNT2Events
});