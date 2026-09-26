#!/usr/bin/env python3
"""抽官网两页里所有 data-en / data-zh 文案，写 scripts/l10n/site-source.json。"""
import json, os
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAGES = ["docs/index.html", "docs/install-extension.html"]
# 页面标题在脚本里切换，不在属性上，单独列
EXTRA = [
    ("TabFlick — tab switcher and search panel for Chrome", "TabFlick — Chrome 的标签切换器和搜索面板"),
    ("TabFlick — Installing the extension", "TabFlick — 扩展安装说明"),
]


class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.found = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "data-en" in a and "data-zh" in a:
            self.found.append((a["data-en"], a["data-zh"]))


def main():
    seen, out = set(), []
    for page in PAGES:
        p = P()
        p.feed(open(os.path.join(ROOT, page)).read())
        for en, zh in p.found + EXTRA:
            if en in seen:
                continue
            seen.add(en)
            out.append({"key": en, "zh": zh, "page": page})
    json.dump(out, open(os.path.join(ROOT, "scripts/l10n/site-source.json"), "w"), ensure_ascii=False, indent=1)
    print(len(out), "site strings")


if __name__ == "__main__":
    main()
