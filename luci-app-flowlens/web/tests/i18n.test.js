import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  detectInitialLanguage,
  languageStorageKey,
  localeForLanguage,
  normalizeLanguage,
  translate
} from '../src/i18n.js';
import { formatClock } from '../src/domain.js';

test('normalizeLanguage maps supported locale variants and falls back', () => {
  assert.equal(normalizeLanguage('zh-CN'), 'zh');
  assert.equal(normalizeLanguage('zh_Hant'), 'zh');
  assert.equal(normalizeLanguage('en-US'), 'en');
  assert.equal(normalizeLanguage('EN_gb'), 'en');
  assert.equal(normalizeLanguage('fr-FR'), 'zh');
  assert.equal(normalizeLanguage('', 'en'), 'en');
});

test('detectInitialLanguage prefers localStorage over document and browser languages', () => {
  const storage = new Map([[languageStorageKey, 'en']]);
  const document = {
    documentElement: {
      lang: 'zh-CN',
      getAttribute: () => null
    },
    body: {
      lang: '',
      getAttribute: () => null
    }
  };
  const navigator = {
    languages: ['zh-CN'],
    language: 'zh-CN'
  };

  assert.equal(detectInitialLanguage({
    document,
    navigator,
    storage: {
      getItem: key => storage.get(key)
    }
  }), 'en');
});

test('detectInitialLanguage falls back through document and browser languages', () => {
  const document = {
    documentElement: {
      lang: '',
      getAttribute: name => name === 'data-language' ? 'en-US' : null
    },
    body: {
      lang: '',
      getAttribute: () => null
    }
  };

  assert.equal(detectInitialLanguage({ document, navigator: { language: 'zh-CN' } }), 'en');
  assert.equal(detectInitialLanguage({ navigator: { languages: ['zh-CN'] } }), 'zh');
  assert.equal(detectInitialLanguage({ navigator: { language: 'fr-FR' } }), 'zh');
});

test('translate returns localized text and falls back to a stable key', () => {
  assert.equal(translate('en', 'status.online'), 'Online');
  assert.equal(translate('zh', 'status.online'), '在线');
  assert.equal(translate('en', 'missing.translation.key'), 'missing.translation.key');
});

test('localeForLanguage and formatClock use the selected locale', () => {
  assert.equal(localeForLanguage('en'), 'en-US');
  assert.equal(localeForLanguage('zh'), 'zh-CN');
  assert.equal(formatClock(0, 'en-US'), '-');

  const original = Date.prototype.toLocaleTimeString;
  let capturedLocale = '';
  let capturedOptions = null;

  Date.prototype.toLocaleTimeString = function(locale, options) {
    capturedLocale = locale;
    capturedOptions = options;
    return 'clock';
  };

  try {
    assert.equal(formatClock(1, 'en-US'), 'clock');
    assert.equal(capturedLocale, 'en-US');
    assert.deepEqual(capturedOptions, {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    });
  } finally {
    Date.prototype.toLocaleTimeString = original;
  }
});
