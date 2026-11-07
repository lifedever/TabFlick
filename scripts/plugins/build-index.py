#!/usr/bin/env python3
"""生成插件商店的目录 plugins/index.json（TabFlick 的「插件」页从这里列可安装的插件、比对更新）。

    python3 scripts/plugins/build-index.py           # 重新生成
    python3 scripts/plugins/build-index.py --check   # 只核对 index.json 和插件文件对不对得上（发布前跑）

plugins/ 下每个带 manifest.json 的目录是一个插件；tests/、以 . 或 _ 开头的文件和目录不进插件包。
每个文件记路径、大小、sha256：客户端下载后逐个核对，对不上就不装。
发布一个插件 = 改了插件文件后重新生成 index.json，连同插件文件一起 push 到 main。
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins")
PATH_RE = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")
MAX_FILES = 20
MAX_BYTES = 4 << 20
MAX_ICON_BYTES = 256 << 10


def check_icon(path):
    """图标要能被 TabFlick 读出来：SVG 是正方形 viewBox、画满；PNG 至少 128×128 的正方形。"""
    data = open(path, "rb").read()
    if path.lower().endswith(".png"):
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            sys.exit(f"✗ {path}: 不是 PNG")
        width, height = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
        if width != height or width < 128:
            sys.exit(f"✗ {path}: PNG 要是至少 128×128 的正方形（现在 {width}×{height}）")
        return
    text = data.decode("utf-8", "replace")
    match = re.search(r'viewBox="\s*([-\d.]+)[\s,]+([-\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)\s*"', text)
    if "<svg" not in text or not match or float(match.group(3)) != float(match.group(4)):
        sys.exit(f"✗ {path}: SVG 要有正方形的 viewBox")
    # 只许引用文件里自己定义的东西（url(#bg)、href="#x"），外部地址、data: 一律不收
    if re.search(r"<(script|image|foreignObject|use)\b", text, re.I) or \
            re.search(r"href\s*=\s*[\"']\s*(?!#)", text) or re.search(r"url\(\s*[\"']?\s*(?!#)", text):
        sys.exit(f"✗ {path}: SVG 里不能有脚本、图片和外部引用")


def plugin_files(directory):
    out = []
    for base, dirs, files in os.walk(directory):
        dirs[:] = sorted(d for d in dirs if d != "tests" and not d.startswith((".", "_")))
        for name in sorted(files):
            if name.startswith((".", "_")):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, directory).replace(os.sep, "/")
            if not PATH_RE.match(rel) or ".." in rel.split("/"):
                sys.exit(f"✗ {directory}: 文件名不合规：{rel}")
            data = open(full, "rb").read()
            out.append({"path": rel, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return out


def build():
    plugins = []
    for name in sorted(os.listdir(ROOT)):
        directory = os.path.join(ROOT, name)
        manifest_path = os.path.join(directory, "manifest.json")
        if name.startswith((".", "_")) or not os.path.isfile(manifest_path):
            continue
        manifest = json.load(open(manifest_path, encoding="utf-8"))
        if manifest.get("id") != name:
            sys.exit(f"✗ {name}: manifest 的 id 是 {manifest.get('id')!r}，必须和目录名一样")
        files = plugin_files(directory)
        if len(files) > MAX_FILES or sum(f["size"] for f in files) > MAX_BYTES:
            sys.exit(f"✗ {name}: 文件太多或太大（上限 {MAX_FILES} 个、{MAX_BYTES} 字节）")
        main = manifest.get("main", "main.js")
        if not any(f["path"] == main for f in files):
            sys.exit(f"✗ {name}: 没有入口脚本 {main}")
        # 要用户填东西的插件必须能测试（设置页的「测试」按钮，用户 2026-11-06：「不然填进去都不知道能不能用」）
        if (manifest.get("settings") or {}).get("inputs"):
            source = open(os.path.join(directory, main), encoding="utf-8").read()
            if not re.search(r"register\(\{[\s\S]*?\btest\b", source):
                sys.exit(f"✗ {name}: 有要用户填的设置项（settings.inputs），register 里必须有 test")
        # 图标：插件目录里的 .svg / .png，不超过 256 KB（同 PluginIconLoader.maxBytes）。商店里没装的插件也画它
        icon = manifest.get("icon")
        if icon is not None:
            match = next((f for f in files if f["path"] == icon), None)
            if not isinstance(icon, str) or not icon.lower().endswith((".svg", ".png")) or match is None:
                sys.exit(f"✗ {name}: icon 必须是插件目录里的一个 .svg / .png：{icon!r}")
            if match["size"] > MAX_ICON_BYTES:
                sys.exit(f"✗ {name}: 图标超过 {MAX_ICON_BYTES} 字节")
            check_icon(os.path.join(directory, icon))
        entry = {k: manifest[k] for k in ("id", "version", "name", "summary", "symbol", "tint", "icon", "hosts", "minAppVersion")
                 if k in manifest}
        entry["files"] = files
        plugins.append(entry)
    return {"schema": 1, "plugins": plugins}


def main():
    index = build()
    path = os.path.join(ROOT, "index.json")
    text = json.dumps(index, ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv:
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != text:
            sys.exit("✗ plugins/index.json 和插件文件对不上，先跑 python3 scripts/plugins/build-index.py")
        print(f"✓ index.json 是最新的（{len(index['plugins'])} 个插件）")
        return
    open(path, "w", encoding="utf-8").write(text)
    print(f"✓ 写入 plugins/index.json：" + "、".join(f"{p['id']} {p['version']}" for p in index["plugins"]))


main()
