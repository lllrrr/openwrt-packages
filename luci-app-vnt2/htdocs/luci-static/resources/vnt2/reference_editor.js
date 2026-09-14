'use strict';

function lineKey(line, section) {
    var s = String(line || '');
    var m = s.match(/^\s*#?\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/);
    if (!m) return null;
    return section ? section + '.' + m[1] : m[1];
}

function lineOptions(line) {
    var opts = [], seen = {}, m, s = String(line || ''), reLong = /--[A-Za-z0-9][A-Za-z0-9_-]*/g, reShort = /(^|\s)-[A-Za-z](?=\s|,|$)/g;
    while ((m = reLong.exec(s)) !== null) { if (!seen[m[0]]) { opts.push(m[0]); seen[m[0]] = true; } }
    while ((m = reShort.exec(s)) !== null) { var v = m[0].trim(); if (!seen[v]) { opts.push(v); seen[v] = true; } }
    return opts;
}

function splitLines(text) {
    return String(text == null ? '' : text).split('\n');
}

function caretQuery(textarea) {
    var all = splitLines(textarea.value);
    var pos = textarea.selectionStart || 0;
    var idx = String(textarea.value).substring(0, pos).split('\n').length - 1;
    if (idx < 0) idx = 0;
    if (idx > all.length - 1) idx = all.length - 1;
    var section = '';
    for (var i = 0; i <= idx; i++) {
        var sm = all[i].match(/^\s*\[([A-Za-z_][A-Za-z0-9_]*)\]\s*$/);
        if (sm) section = sm[1];
    }
    var line = all[idx] || '';
    return { key: lineKey(line, section) || '', lineText: line };
}

function refQuery(spanEl) {
    return { key: spanEl.getAttribute('data-key') || '', lineText: spanEl.textContent || '' };
}

function collectKeysByLine(text, includeCommented) {
    var keys = {}, lines = [], section = '';
    String(text || '').split('\n').forEach(function(line, idx) {
        var trimmed = line.trim();
        var sm = trimmed.match(/^\s*\[([A-Za-z_][A-Za-z0-9_]*)\]\s*$/);
        if (sm) { section = sm[1]; return; }
        var re = includeCommented
            ? /^\s*#?\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*=/
            : /^\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*=/;
        var m = line.match(re);
        if (!m) return;
        var key = section ? section + '.' + m[1] : m[1];
        keys[key] = true;
        lines[idx] = key;
    });
    return { keys:keys, lines:lines };
}

function findMatchLine(lines, query) {
    var key = (query && query.key) || '';
    var want = String((query && query.lineText) || '').trim();
    var bare = key.indexOf('.') > 0 ? key.split('.').pop() : '';
    var re = /^\s*#?\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*=/;
    var section = '', i, m;
    if (key) {
        for (i = 0; i < lines.length; i++) {
            var t = String(lines[i] || '').trim();
            var sm = t.match(/^\[([A-Za-z_][A-Za-z0-9_]*)\]$/);
            if (sm) { section = sm[1]; continue; }
            m = String(lines[i] || '').match(re);
            if (!m) continue;
            var full = section ? section + '.' + m[1] : m[1];
            if (full === key || m[1] === key || (bare && m[1] === bare)) return i;
        }
    }
    if (want) {
        for (i = 0; i < lines.length; i++) {
            if (String(lines[i] || '').trim() === want) return i;
        }
    }
    return -1;
}

function buildReference(text) {
    var pre = E('pre', {'class':'vnt2-ref-content'});
    var lines = String(text || _('No reference output')).split('\n');
    var section = '';
    lines.forEach(function(line, idx) {
        var sm = line.match(/^\s*\[([A-Za-z_][A-Za-z0-9_]*)\]\s*$/);
        if (sm) section = sm[1];
        var k = lineKey(line, section);
        var opts = lineOptions(line);
        var attrs = {'class':'vnt2-ref-line'};
        if (k) attrs['data-key'] = k;
        if (opts.length) attrs['data-options'] = opts.join(' ');
        var lineEl = E('span', attrs);
        lineEl.appendChild(document.createTextNode(line || ' '));
        pre.appendChild(lineEl);
        if (idx < lines.length - 1) pre.appendChild(document.createTextNode('\n'));
    });
    return pre;
}

function fieldGuide() {
    var rows = [
        ['[string]', _('Text input'), _('For network_code, password, device_name, tun_name.')],
        ['[array]', _('Multi-value textarea'), _('One value per line in the generated form.')],
        ['[bool]', _('Capsule switch'), _('For rtx, fec, no_punch, enabled.')],
        ['[int]', _('Number input'), _('For mtu, ctrl_port, ports and timeouts.')],
        ['[select]', _('Dropdown'), _('Use an options line, for example: options: tun,tap,no.')],
        ['[section]', _('Sub section'), _('For sections such as [ikev2].')]
    ];
    return E('div', {'class':'vnt2-field-guide'}, [
        E('div', {'class':'vnt2-field-guide-title'}, _('Field Type Guide')),
        E('div', {'class':'vnt2-field-guide-grid'}, rows.map(function(r) {
            return E('div', {'class':'vnt2-field-guide-row'}, [
                E('span', {'class':'vnt2-field-type-pill'}, r[0]),
                E('div', {}, [E('b', {}, r[1]), E('small', {}, r[2])])
            ]);
        })),
        E('div', {'class':'vnt2-field-guide-extend'}, [
            E('b', {}, _('Select extra input')),
            E('code', {}, '# extend: finger=text(prefix=finger:, placeholder=finger:SHA256)'),
            E('small', {}, _('Place it below a [select] options line. When the selected option is finger, the form shows a text input below the dropdown and saves the text with the finger: prefix.'))
        ])
    ]);
}

function insertAt(textarea, snippet) {
    var start = textarea.selectionStart || 0, end = textarea.selectionEnd || start;
    var v = textarea.value;
    textarea.value = v.substring(0, start) + snippet + v.substring(end);
    textarea.selectionStart = textarea.selectionEnd = start + snippet.length;
    textarea.dispatchEvent(new Event('input', { bubbles:true }));
    textarea.focus();
}

var snippets = {
    string: '# Parameter description\n# [string]\n# Example: value\nname = ""\n',
    array: '# Parameter description\n# [array]\n# One value per line\n# Example: value\nname = []\n',
    bool: '# Parameter description\n# [bool]\nname = false\n',
    int: '# Parameter description\n# [int]\nname = 0\n',
    select: '# Parameter description\n# [select]\n# options: tun,tap,no\nname = "tun"\n',
    section: '# Section description\n# [section]\n[section_name]\n\n# Enable section\n# [bool]\nenabled = false\n'
};

function chips(textarea) {
    return E('div', {'class':'vnt2-insert-chips'}, Object.keys(snippets).map(function(k) {
        return E('button', {'type':'button','class':'vnt2-insert-chip','click':function(){ insertAt(textarea, snippets[k]); }}, '+' + k);
    }));
}

var VNT2ReferenceEditor = {
    build: function(opts) {
        opts = opts || {};
        var textarea = E('textarea', {
            'class':'vnt2-input vnt2-ref-textarea',
            'readonly': opts.readonly ? 'readonly' : null,
            'wrap':'off',
            'spellcheck':'false'
        }, opts.value || '');
        var refText = opts.referenceText || '';
        var refLines = splitLines(refText || _('No reference output'));
        var refContent = buildReference(refText);
        var includeCommented = !!opts.includeCommentedParams;
        var refPane, errorBox, toolsBox, timer = null;
        function schedule(delay, force) {
            if (timer) window.clearTimeout(timer);
            timer = window.setTimeout(function() { window.requestAnimationFrame(function() { syncRefFromEditor(); }); }, delay || 0);
        }
        function syncRefFromEditor() {
            refContent.querySelectorAll('.is-active').forEach(function(el) { el.classList.remove('is-active'); });
            var idx = findMatchLine(refLines, caretQuery(textarea));
            if (idx < 0) return;
            var target = refContent.querySelectorAll('.vnt2-ref-line')[idx];
            if (!target) return;
            target.classList.add('is-active');
            try { target.scrollIntoView({ block:'center', inline:'nearest', behavior:'smooth' }); }
            catch(e) { refContent.scrollTop = Math.max(0, target.offsetTop - refContent.clientHeight / 2); }
        }
        function clearValidation() {
            textarea.classList.remove('vnt2-input-error');
            if (errorBox) errorBox.innerHTML = '';
        }
        function selectLine(lineNo) {
            var lines = textarea.value.split('\n'), pos = 0;
            for (var i = 0; i < lineNo && i < lines.length; i++) pos += lines[i].length + 1;
            textarea.focus();
            textarea.selectionStart = pos;
            textarea.selectionEnd = pos + (lines[lineNo] || '').length;
            var top = Math.max(0, lineNo * parseFloat(window.getComputedStyle(textarea).lineHeight || 18) - textarea.clientHeight / 2);
            textarea.scrollTop = top;
        }
        function syncEditorFromRef(spanEl) {
            var idx = findMatchLine(splitLines(textarea.value), refQuery(spanEl));
            if (idx >= 0) selectLine(idx);
        }
        function bindReferenceClicks() {
            refContent.addEventListener('click', function(ev) {
                var el = ev.target;
                while (el && el !== refContent && !(el.classList && el.classList.contains('vnt2-ref-line'))) el = el.parentNode;
                if (!el || el === refContent) return;
                syncEditorFromRef(el);
            });
        }
        function unknownItems() {
            var cur = collectKeysByLine(textarea.value, includeCommented);
            var ref = collectKeysByLine(opts.referenceText || '', true);
            var out = [];
            Object.keys(cur.lines).forEach(function(i) {
                var key = cur.lines[i];
                if (key && !ref.keys[key]) out.push({ line: parseInt(i), key: key });
            });
            return out;
        }
        function showValidationErrors(errors) {
            var items = unknownItems();
            textarea.classList.add('vnt2-input-error');
            if (!errorBox) return;
            errorBox.innerHTML = '';
            var nodes = [];
            var title = opts.unknownParamsTitle;
            if (title == null) title = _('Unknown parameters, not found in official --conf-example:');
            if (items.length) {
                if (title) nodes.push(E('div', {'class':'vnt2-ref-error-title'}, title));
                nodes.push(E('div', {'class':'vnt2-ref-error-list'}, items.map(function(it) {
                    return E('button', {'type':'button','class':'vnt2-ref-error-chip','click':function(){ selectLine(it.line); }}, it.key + ' #' + (it.line + 1));
                })));
            } else if (errors && errors.length) {
                nodes.push(E('div', {'class':'vnt2-ref-error-title'}, errors.join('\n')));
            }
            if (nodes.length) errorBox.appendChild(E('div', {'class':'vnt2-ref-error-box'}, nodes));
            if (items.length) selectLine(items[0].line);
        }
        toolsBox = E('div', {'class':'vnt2-ref-tools'});
        if (opts.insertChips) toolsBox.appendChild(chips(textarea));
        if (opts.guide) toolsBox.appendChild(fieldGuide());
        var hasTools = !!(opts.insertChips || opts.guide);
        var toolsInRef = !!(hasTools && opts.toolsInReferencePane);
        var refTitle = E('span', {'class':'vnt2-ref-title' + (toolsInRef ? ' is-clickable' : '')}, opts.referenceTitle || _('Official --conf-example'));
        var closeBtn = E('button', {'type':'button','class':'vnt2-icon-btn vnt2-ref-close','title':_('Hide official reference')}, '×');
        var toolsToggle = null;
        function showReferenceContent() {
            refContent.classList.remove('is-hidden');
            toolsBox.classList.add('is-hidden');
            if (toolsToggle) {
                toolsToggle.textContent = '?';
                toolsToggle.title = _('Show Tips & Shortcuts');
            }
            schedule(80, true);
        }
        function showToolsContent() {
            refContent.classList.add('is-hidden');
            toolsBox.classList.remove('is-hidden');
            if (toolsToggle) {
                toolsToggle.textContent = '\u2261';
                toolsToggle.title = _('Show official --conf-example');
            }
        }
        if (toolsInRef) {
            toolsBox.classList.add('is-hidden');
            toolsToggle = E('button', {'type':'button','class':'vnt2-icon-btn vnt2-ref-tools-toggle','title':_('Show Tips & Shortcuts')}, '?');
            toolsToggle.addEventListener('click', function() {
                if (toolsBox.classList.contains('is-hidden')) showToolsContent();
                else showReferenceContent();
            });
            refTitle.addEventListener('click', showReferenceContent);
        }
        refPane = E('div', {'class':'vnt2-ref-pane'}, [
            E('div', {'class':'vnt2-ref-pane-head'}, [
                E('div', {'class':'vnt2-ref-head-left'}, toolsToggle ? [refTitle, toolsToggle] : [refTitle]),
                closeBtn
            ]),
            refContent,
            toolsInRef ? toolsBox : E('span', {})
        ]);
        var paneToggle = E('button', {
            'type':'button',
            'class':'vnt2-icon-btn vnt2-ref-pane-toggle',
            'title':_('Hide official reference')
        }, '?');
        bindReferenceClicks();
        textarea.addEventListener('input', function(){ clearValidation(); schedule(60, false); if (opts.onInput) opts.onInput(textarea.value); });
        textarea.addEventListener('keyup', function(){ schedule(20, false); });
        textarea.addEventListener('click', function(){ schedule(20, false); });
        textarea.addEventListener('focus', function(){ schedule(180, true); });
        textarea.addEventListener('blur', function(){ schedule(260, true); });
        window.addEventListener('resize', function(){ schedule(260, true); });
        if (window.visualViewport) window.visualViewport.addEventListener('resize', function(){ schedule(360, true); });
        var right = [E('div', {'class':'vnt2-ref-pane-head'}, [
            E('span', {}, opts.editorTitle || _('Editor')),
            paneToggle
        ])];
        if (opts.meta) right.push(opts.meta);
        errorBox = E('div', {'class':'vnt2-ref-error-host'});
        right.push(errorBox);
        if (hasTools && !opts.toolsInReferencePane) right.push(toolsBox);
        right.push(textarea);
        if (opts.previewNode) right.push(opts.previewNode);
        var editorNode = E('div', {'class':'vnt2-ref-editor'}, [
            refPane,
            E('div', {'class':'vnt2-edit-pane'}, right)
        ]);
        function setPaneVisible(visible) {
            refPane.classList.toggle('is-hidden', !visible);
            editorNode.classList.toggle('ref-collapsed', !visible);
            paneToggle.title = visible ? _('Hide official reference') : _('Show official reference');
            if (visible) schedule(80, true);
        }
        paneToggle.addEventListener('click', function() {
            setPaneVisible(refPane.classList.contains('is-hidden'));
        });
        closeBtn.addEventListener('click', function() { setPaneVisible(false); });
        setPaneVisible(true);
        return {
            node: editorNode,
            textarea: textarea,
            getValue: function(){ return textarea.value; },
            setValue: function(v){ textarea.value = v || ''; clearValidation(); schedule(80, true); },
            showValidationErrors: showValidationErrors,
            clearValidation: clearValidation
        };
    },
    fieldGuide: fieldGuide,
    insertChips: chips
};

return L.Class.extend({
    VNT2ReferenceEditor: VNT2ReferenceEditor
});
