#!/usr/bin/env python3
"""校验 scripts/l10n/site-<lang>.json，生成 docs/i18n.js（数据 + site-runtime.js）。"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIR = os.path.join(ROOT, "scripts", "l10n")
LANGS = ["zh-Hant", "ja", "ko", "es", "fr", "de"]
KEEP = ["TabFlick", "Chrome", "GitHub", "chrome://extensions", "⌃", "⇥", "⌘", "⌥", "MIT"]


def main():
    source = json.load(open(os.path.join(DIR, "site-source.json")))
    keys = [e["key"] for e in source]
    data, errors = {}, []
    for code in LANGS:
        path = os.path.join(DIR, f"site-{code}.json")
        if not os.path.exists(path):
            print(f"⚠️  [{code}] 没有官网译文")
            continue
        t = json.load(open(path))
        for k in keys:
            v = t.get(k)
            if not v:
                errors.append(f"[{code}] 缺译: {k[:60]!r}")
                continue
            for token in KEEP:
                if token in k and token not in v:
                    errors.append(f"[{code}] 丢了「{token}」: {k[:50]!r} → {v[:50]!r}")
        data[code] = {k: t[k] for k in keys if t.get(k)}
    for e in errors:
        print("❌", e)
    if errors:
        sys.exit(f"{len(errors)} 个错误，没写 docs/i18n.js")
    runtime = open(os.path.join(DIR, "site-runtime.js")).read()
    out = ("// 由 scripts/l10n/build_site.py 生成，别手改。\n"
           "window.TABFLICK_I18N = " + json.dumps(data, ensure_ascii=False, indent=1) + ";\n\n" + runtime)
    open(os.path.join(ROOT, "docs", "i18n.js"), "w").write(out)
    print("✅ docs/i18n.js", {k: len(v) for k, v in data.items()})


if __name__ == "__main__":
    main()
