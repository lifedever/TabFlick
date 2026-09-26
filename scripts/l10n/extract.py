#!/usr/bin/env python3
"""从 helper 源码抽出所有 L10n.t / hotkeyNote 的中英文案，写 scripts/l10n/source.json。

键是**英文模板**：插值换成 {0} {1}…，和运行时 L10nText 拼出来的模板逐字一致
（转义、多行字面量的缩进剥离都按 Swift 规则处理）。值里带中文原文给译者做参考。
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "helper", "Sources", "tabflick")
OUT = os.path.join(ROOT, "scripts", "l10n", "source.json")
CALLS = ("L10n.t(", "hotkeyNote(")


class ParseError(Exception):
    pass


def skip_ws(s, i):
    while i < len(s):
        if s[i] in " \t\r\n":
            i += 1
        elif s.startswith("//", i):
            i = s.index("\n", i)
        else:
            break
    return i


def skip_interpolation(s, i):
    """i 指向 `\\(` 之后的第一个字符；返回匹配的 `)` 之后的位置。里面可能嵌套字符串字面量。"""
    depth = 1
    while i < len(s):
        c = s[i]
        if c == '"':
            _, i = parse_literal(s, i)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ParseError("unterminated interpolation")


def decode_escape(s, i):
    """i 指向反斜杠之后。返回 (字符, 新位置)。"""
    c = s[i]
    table = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\", "0": "\0"}
    if c in table:
        return table[c], i + 1
    if c == "u" and s[i + 1] == "{":
        j = s.index("}", i)
        return chr(int(s[i + 2:j], 16)), j + 1
    raise ParseError(f"unknown escape \\{c}")


def parse_literal(s, i):
    """i 指向开头的引号。返回 (模板, 结束位置)。"""
    if s.startswith('"""', i):
        return parse_multiline(s, i)
    assert s[i] == '"'
    i += 1
    out, n = [], 0
    while True:
        c = s[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\n":
            raise ParseError("newline in single-line literal")
        if c == "\\":
            if s[i + 1] == "(":
                i = skip_interpolation(s, i + 2)
                out.append("{%d}" % n)
                n += 1
                continue
            ch, i = decode_escape(s, i + 1)
            out.append(ch)
            continue
        out.append(c)
        i += 1


def parse_multiline(s, i):
    start = s.index("\n", i) + 1
    # 找收尾的 """（不在插值里）
    j, raw_end = start, None
    while j < len(s):
        if s.startswith("\\(", j):
            j = skip_interpolation(s, j + 2)
            continue
        if s.startswith("\\", j):
            j += 2
            continue
        if s.startswith('"""', j):
            raw_end = j
            break
        j += 1
    if raw_end is None:
        raise ParseError("unterminated multiline literal")
    line_start = s.rindex("\n", 0, raw_end) + 1
    indent = s[line_start:raw_end]
    body = s[start:line_start - 1] if line_start - 1 >= start else ""
    lines = body.split("\n")
    lines = [l[len(indent):] if l.startswith(indent) else l.lstrip(" \t") for l in lines]
    text = "\n".join(lines)
    # 逐字符解码（转义、插值、行尾反斜杠续行）
    out, n, k = [], 0, 0
    while k < len(text):
        c = text[k]
        if c == "\\":
            if text[k + 1] == "(":
                k = skip_interpolation(text, k + 2)
                out.append("{%d}" % n)
                n += 1
                continue
            if text[k + 1] == "\n":
                k += 2
                continue
            ch, k = decode_escape(text, k + 1)
            out.append(ch)
            continue
        out.append(c)
        k += 1
    return "".join(out), raw_end + 3


def main():
    entries, seen = [], {}
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".swift"):
            continue
        s = open(os.path.join(SRC, name)).read()
        for call in CALLS:
            pos = 0
            while True:
                pos = s.find(call, pos)
                if pos < 0:
                    break
                line = s.count("\n", 0, pos) + 1
                line_head = s[s.rfind("\n", 0, pos) + 1:pos]
                i = skip_ws(s, pos + len(call))
                pos += len(call)
                if "//" in line_head:
                    continue  # 注释里提到的调用，不是真调用
                if s[i] != '"':
                    continue  # 函数定义本身、或参数是变量
                try:
                    zh, i = parse_literal(s, i)
                    i = skip_ws(s, i)
                    if s[i] != ",":
                        continue
                    i = skip_ws(s, i + 1)
                    if s[i] != '"':
                        continue
                    en, i = parse_literal(s, i)
                except ParseError as e:
                    sys.exit(f"{name}:{line}: {e}")
                ref = f"{name}:{line}"
                if en in seen:
                    seen[en]["refs"].append(ref)
                    continue
                seen[en] = {"key": en, "zh": zh, "refs": [ref]}
                entries.append(seen[en])
    json.dump(entries, open(OUT, "w"), ensure_ascii=False, indent=1)
    print(f"{len(entries)} unique strings → {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
