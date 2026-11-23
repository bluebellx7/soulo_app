const language = globalThis.browser?.i18n?.getUILanguage?.() || globalThis.chrome?.i18n?.getUILanguage?.() || navigator.language;
if (/^zh\b/i.test(language)) {
    document.documentElement.lang = "zh-Hans";
    document.querySelector('main[lang="en"]').hidden = true;
    document.querySelector('main[lang="zh-Hans"]').hidden = false;
}
