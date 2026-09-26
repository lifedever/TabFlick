#!/usr/bin/env python3
"""校验 scripts/l10n/<lang>.json 并生成 helper/Sources/tabflick/L10nTables.swift。

  python3 scripts/l10n/extract.py   # 源码改了文案后先重新抽取
  python3 scripts/l10n/build.py     # 校验全部语言，全过才写 Swift 文件

校验失败一律退出非 0、不写文件：缺键、多键、占位符对不上、换行数不同、
不该翻译的专有名词 / 快捷键符号丢了。缺键只警告（运行时会退回英文并记日志），
但 --strict 下也算失败，发版前用 --strict。
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIR = os.path.join(ROOT, "scripts", "l10n")
OUT = os.path.join(ROOT, "helper", "Sources", "tabflick", "L10nTables.swift")
LANGS = [("zh-Hant", "zhHant"), ("ja", "ja"), ("ko", "ko"), ("es", "es"), ("fr", "fr"), ("de", "de")]
KEEP = ["TabFlick", "Chrome", "GitHub", "YouTube", "Raycast", "macOS", "chrome://extensions",
        "⌃", "⇥", "⌘", "⌥", "⇧", "↩", "%s"]
PH = re.compile(r"\{\d+\}")
# 紧跟在字母后面的占位符是英文复数后缀（`tab{2}` → "" / "s"）。没有这种变化的语言
# 必须去掉它，否则菜单里会出现「3個のタブs」；有的语言（西法德）可以留着用。
SUFFIX = re.compile(r"(?<=[A-Za-z]{2})\{\d+\}")  # v{0} 这种版本号不算
NO_PLURAL_SUFFIX = {"zh-Hant", "ja", "ko"}


def swift_literal(s):
    out = []
    for c in s:
        if c == "\\": out.append("\\\\")
        elif c == '"': out.append('\\"')
        elif c == "\n": out.append("\\n")
        elif c == "\t": out.append("\\t")
        elif c == "\r": out.append("\\r")
        else: out.append(c)
    return '"' + "".join(out) + '"'


def main():
    strict = "--strict" in sys.argv
    source = json.load(open(os.path.join(DIR, "source.json")))
    keys = [e["key"] for e in source]
    errors, warnings, tables = [], [], {}
    for code, case in LANGS:
        path = os.path.join(DIR, f"{code}.json")
        if not os.path.exists(path):
            warnings.append(f"[{code}] 没有译文文件，整种语言会退回英文")
            tables[case] = {}
            continue
        data = json.load(open(path))
        missing = [k for k in keys if k not in data or not str(data[k]).strip()]
        extra = [k for k in data if k not in set(keys)]
        for k in missing:
            (errors if strict else warnings).append(f"[{code}] 缺译: {k[:70]!r}")
        for k in extra:
            warnings.append(f"[{code}] 多余的键（源码里已经没有）: {k[:70]!r}")
        for k in keys:
            v = data.get(k)
            if not v:
                continue
            suffix = set(SUFFIX.findall(k))
            required = sorted(p for p in PH.findall(k) if p not in suffix)
            present = PH.findall(v)
            if sorted(p for p in present if p not in suffix) != required:
                errors.append(f"[{code}] 占位符不一致: {k[:60]!r} → {v[:60]!r}")
            if code in NO_PLURAL_SUFFIX and any(p in present for p in suffix):
                errors.append(f"[{code}] 这门语言没有复数后缀，去掉 {sorted(suffix)}: {v[:60]!r}")
            if k.count("\n") != v.count("\n"):
                errors.append(f"[{code}] 换行数不一致: {k[:60]!r}")
            for token in KEEP:
                if token in k and token not in v:
                    errors.append(f"[{code}] 丢了「{token}」: {k[:60]!r} → {v[:60]!r}")
        tables[case] = {k: data[k] for k in keys if data.get(k)}
    for w in warnings:
        print("⚠️ ", w)
    for e in errors:
        print("❌", e)
    if errors:
        sys.exit(f"{len(errors)} 个错误，没有写 {os.path.relpath(OUT, ROOT)}")

    lines = ["// 由 scripts/l10n/build.py 从 scripts/l10n/<lang>.json 生成，别手改。",
             "// 键是英文模板（插值换成 {0} {1}…），见 L10n.swift。", "",
             "enum L10nTables {",
             "    static func table(for language: L10n.Language) -> [String: String] {",
             "        switch language {"]
    for _, case in LANGS:
        lines.append(f"        case .{case}: return {case}")
    lines += ["        default: return [:]", "        }", "    }", ""]
    for _, case in LANGS:
        lines.append(f"    private static let {case}: [String: String] = [")
        for k, v in tables[case].items():
            lines.append(f"        {swift_literal(k)}: {swift_literal(v)},")
        if not tables[case]:
            lines.append("        :")
        lines.append("    ]")
        lines.append("")
    lines.append("}")
    open(OUT, "w").write("\n".join(lines) + "\n")
    counts = ", ".join(f"{c} {len(tables[case])}/{len(keys)}" for c, case in LANGS)
    print(f"✅ 写入 {os.path.relpath(OUT, ROOT)}（{counts}）")


if __name__ == "__main__":
    main()
