// 官网多语言切换。中英文案直接在元素的 data-zh / data-en 上；其他语言按英文原文查
// TABFLICK_I18N（由 scripts/l10n/build_site.py 生成在本文件顶部）。赋值只走 textContent。
(function () {
  const LANGS = [
    ["zh", "简体中文"], ["zh-Hant", "繁體中文"], ["en", "English"], ["ja", "日本語"],
    ["ko", "한국어"], ["es", "Español"], ["fr", "Français"], ["de", "Deutsch"],
  ];
  const KEY = "tabflick-lang";

  function resolve(tag) {
    const t = (tag || "").toLowerCase();
    if (t.startsWith("zh")) {
      return /hant|-tw$|-hk$|-mo$/.test(t) ? "zh-Hant" : "zh";
    }
    for (const code of ["ja", "ko", "es", "fr", "de"]) if (t.startsWith(code)) return code;
    return "en";
  }

  function translate(lang, en, zh) {
    if (lang === "zh") return zh;
    if (lang === "en") return en;
    const table = (window.TABFLICK_I18N || {})[lang] || {};
    if (table[en]) return table[en];
    return lang === "zh-Hant" ? zh : en;
  }

  window.TabFlickI18n = {
    init(title) {
      const select = document.getElementById("langSelect");
      for (const [code, name] of LANGS) {
        const opt = document.createElement("option");
        opt.value = code;
        opt.textContent = name;
        select.appendChild(opt);
      }
      function apply(lang) {
        document.documentElement.lang = lang;
        for (const el of document.querySelectorAll("[data-zh][data-en]")) {
          el.textContent = translate(lang, el.dataset.en, el.dataset.zh);
        }
        document.title = translate(lang, title.en, title.zh);
        select.value = lang;
      }
      let lang = localStorage.getItem(KEY);
      if (!LANGS.some(([code]) => code === lang)) lang = resolve(navigator.language);
      apply(lang);
      select.addEventListener("change", () => {
        localStorage.setItem(KEY, select.value);
        apply(select.value);
      });
    },
  };
})();
