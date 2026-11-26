#!/usr/bin/env python3
"""生成插件商店的目录 plugins/index.json（TabFlick 的「插件」页从这里列可安装的插件、比对更新）。

    python3 scripts/plugins/build-index.py           # 重新生成并签名
    python3 scripts/plugins/build-index.py --check   # 只核对 index.json 和插件文件对不对得上、签名对不对（发布前跑）
    python3 scripts/plugins/build-index.py --create-key   # 生成签名钥匙（只在第一次、或者换钥匙时）

plugins/ 下每个带 manifest.json 的目录是一个插件；tests/、以 . 或 _ 开头的文件和目录不进插件包。
每个文件记路径、大小、sha256：客户端下载后逐个核对，对不上就不装。
发布一个插件 = 改了插件文件后重新生成 index.json，连同插件文件一起 push 到 main。

签名（2026-11-26）：index.json 用 Ed25519 私钥签，写进 index.json.sig；TabFlick 用编进去的公钥（PluginStoreIndex.swift 的
StoreSignature.publicKeys）核对，对不上整份不认。私钥是发布者自己保管的一个文件（base64，权限 600），不进仓库、
不进命令行参数。它在哪：环境变量 TABFLICK_SIGNING_KEY，没有就读 scripts/plugins/signing-key.local 里写的路径
（这个文件 .gitignore 掉了：路径是发布者本机的，不该出现在公开仓库里）。
"""
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins")
HERE = os.path.dirname(os.path.abspath(__file__))
SIGN_SWIFT = os.path.join(HERE, "sign.swift")
INDEX_SWIFT = os.path.join(HERE, "..", "..", "helper", "Sources", "tabflick", "PluginStoreIndex.swift")
KEY_PATH_FILE = os.path.join(HERE, "signing-key.local")
MANIFEST_SWIFT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "helper", "Sources", "tabflick",
                              "PluginManifest.swift")
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


def script_policy():
    """App 插件脚本的禁用词，直接从 PluginManifest.swift 里读（`PluginScriptPolicy.forbiddenWords`），两边只有一份。"""
    source = open(MANIFEST_SWIFT, encoding="utf-8").read()
    match = re.search(r"forbiddenWords: Set<String> = \[(.*?)\]", source, re.S)
    if not match:
        sys.exit("✗ 读不到 PluginScriptPolicy.forbiddenWords")
    body = "\n".join(line.split("//")[0] for line in match.group(1).splitlines())
    return set(re.findall(r'"([a-z_]+)"', body))


def check_app(name, manifest, main_source):
    """App 插件（manifest 的 app + contributes.commands）：同 PluginApp / PluginCommand / PluginScriptPolicy 的规矩。
    TabFlick 装的时候也会拦，这里先拦是为了别把装不上的插件发出去。"""
    app = manifest.get("app")
    commands = (manifest.get("contributes") or {}).get("commands")
    if commands is not None and not app:
        sys.exit(f"✗ {name}: 有 commands 就必须声明 app")
    if app is None:
        return
    bundle = app.get("bundleId", "")
    if not re.match(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$", bundle) or not 3 <= len(bundle) <= 155 \
            or bundle.lower().startswith("com.apple."):
        sys.exit(f"✗ {name}: app.bundleId 不合规，或者是苹果自己的 App：{bundle!r}")
    for scheme in app.get("schemes", []):
        if not re.match(r"^[a-z][a-z0-9+.-]{1,31}$", scheme) or scheme in (
                "http", "https", "file", "ftp", "sftp", "smb", "afp", "nfs", "vnc", "ssh", "telnet", "data",
                "javascript", "mailto", "tel", "sms", "facetime", "itms", "macappstore") \
                or scheme.startswith(("x-apple", "com.apple")):
            sys.exit(f"✗ {name}: app.schemes 里有不收的 scheme：{scheme!r}")
    scripts = app.get("scripts", {})
    if scripts and manifest.get("hosts"):
        sys.exit(f"✗ {name}: 能跑脚本的插件不许联网（hosts 必须是空的）")
    forbidden = script_policy()
    for key, body in scripts.items():
        words = set(re.split(r"[^a-z0-9_]+", body.lower()))
        bad = sorted(words & forbidden)
        if not body.strip() or len(body) > 2000 or not body.isascii() or any(c in body for c in "«»|\\") or bad:
            sys.exit(f"✗ {name}: 脚本 {key} 不合规{('（' + '、'.join(bad) + '）') if bad else ''}")
    if commands:
        ids = [c.get("id") for c in commands]
        if len(ids) != len(set(ids)) or not all(isinstance(i, str) and re.match(r"^[a-z][a-z0-9-]{0,39}$", i) for i in ids):
            sys.exit(f"✗ {name}: 命令 id 不合规或重复")
        if not re.search(r"register\(\{[\s\S]*?\bcommand\b", main_source):
            sys.exit(f"✗ {name}: 有 commands，register 里必须有 command")


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
        source = open(os.path.join(directory, main), encoding="utf-8").read()
        check_app(name, manifest, source)
        # 要用户填东西的插件必须能测试（设置页的「测试」按钮，用户 2026-11-06：「不然填进去都不知道能不能用」）
        if (manifest.get("settings") or {}).get("inputs"):
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
        # App 插件：商店里装着那个 App 时画它自己的图标
        if manifest.get("app"):
            entry["app"] = manifest["app"]["bundleId"]
        entry["files"] = files
        plugins.append(entry)
    return {"schema": 1, "plugins": plugins}


def swift(args, stdin=""):
    result = subprocess.run(["swift", SIGN_SWIFT, *args], input=stdin, capture_output=True, text=True)
    if result.returncode != 0 and args[0] != "verify":
        sys.exit(f"✗ sign.swift {args[0]} 失败：{result.stderr.strip()}")
    return result


def embedded_public_keys():
    source = open(INDEX_SWIFT, encoding="utf-8").read()
    match = re.search(r"publicKeys: \[String\] = \[(.*?)\]", source, re.S)
    return re.findall(r'"([A-Za-z0-9+/=]{44})"', match.group(1)) if match else []


def key_path():
    path = os.environ.get("TABFLICK_SIGNING_KEY")
    if not path and os.path.exists(KEY_PATH_FILE):
        path = open(KEY_PATH_FILE, encoding="utf-8").read().strip()
    if not path:
        sys.exit("✗ 不知道签名私钥在哪：设环境变量 TABFLICK_SIGNING_KEY，或者把路径写进 scripts/plugins/signing-key.local")
    return os.path.expanduser(path)


def create_key():
    """生成签名私钥写进 key_path()（权限 600），打印公钥。已经有了就不动：覆盖了等于换钥匙，老版本 TabFlick 全都不认。"""
    path = key_path()
    if os.path.exists(path):
        sys.exit(f"✗ {path} 已经有了，不覆盖（要换钥匙先自己挪走它）")
    private, public = swift(["keygen"]).stdout.split()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(private + "\n")
    print(f"✓ 私钥写进了 {path}")
    print(f"  公钥（编进 PluginStoreIndex.swift 的 StoreSignature.publicKeys）：{public}")


def sign(path):
    key_file = key_path()
    if not os.path.exists(key_file):
        sys.exit(f"✗ 签名私钥不在 {key_file}（iCloud 云盘还没同步下来？或者先跑 --create-key）")
    private = open(key_file, encoding="utf-8").read().strip()
    signature = swift(["sign", path], stdin=private).stdout.strip()
    open(path + ".sig", "w").write(signature + "\n")


def verify(path):
    keys = embedded_public_keys()
    if not keys:
        sys.exit("✗ PluginStoreIndex.swift 里还没有编进公钥（StoreSignature.publicKeys）")
    if not os.path.exists(path + ".sig") or swift(["verify", path, path + ".sig", *keys]).returncode != 0:
        sys.exit("✗ index.json.sig 和 index.json、编进 TabFlick 的公钥对不上，先跑 python3 scripts/plugins/build-index.py")


def main():
    if "--create-key" in sys.argv:
        create_key()
        return
    index = build()
    path = os.path.join(ROOT, "index.json")
    text = json.dumps(index, ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv:
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != text:
            sys.exit("✗ plugins/index.json 和插件文件对不上，先跑 python3 scripts/plugins/build-index.py")
        verify(path)
        print(f"✓ index.json 是最新的、签名对得上（{len(index['plugins'])} 个插件）")
        return
    open(path, "w", encoding="utf-8").write(text)
    sign(path)
    verify(path)
    print(f"✓ 写入 plugins/index.json 并签名：" + "、".join(f"{p['id']} {p['version']}" for p in index["plugins"]))


main()
