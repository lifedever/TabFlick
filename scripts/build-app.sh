#!/bin/bash
# 构建 TabFlick.app 并打成 DMG。
#
#   ./scripts/build-app.sh            # 版本号取自最近的 git tag
#   ./scripts/build-app.sh 0.2.0      # 显式指定
#
# 产物：build/TabFlick.app 和 build/TabFlick-<版本>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/TabFlick.app"
DMG_STAGE="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/TabFlick-$VERSION.dmg"

# 开头就把所有中间产物清干净。脚本随时可能被 Ctrl+C 打断，只靠结尾清理
# 会留下暂存目录；下次 `cp -R src dst` 遇到已存在的 dst 语义是「拷进去」
# 而不是「替换」，结果是新 app 被嵌套进旧 app 里发出去。
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DMG_STAGE"

echo "▸ 编译 universal 二进制 (arm64 + x86_64)…"
(cd helper && swift build -c release --arch arm64 --arch x86_64)
BIN_DIR="$ROOT/helper/.build/apple/Products/Release"
[ -f "$BIN_DIR/tabflick" ] || BIN_DIR="$ROOT/helper/.build/release"

cp "$BIN_DIR/tabflick" "$APP/Contents/MacOS/TabFlick"

echo "▸ 组装 bundle…"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"

[ -f assets/TabFlick.icns ] || ./scripts/make-icon.sh
cp assets/TabFlick.icns "$APP/Contents/Resources/TabFlick.icns"

# SPM 的 .process 资源会生成 {Package}_{Target}.bundle。现在 TabFlick 零依赖，
# 一个都不会产生 —— 但这里必须用 glob 而不是写死名字：哪天加了带资源的依赖，
# 漏拷一个就是运行时 Bundle.module 直接 SIGTRAP，而且崩溃点离这里很远。
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# 优先用本机的开发证书。
#
# ad-hoc 签名（--sign -）的 TCC 记录绑定 cdhash，而 cdhash 随代码变化 ——
# 每次重新构建，macOS 都会把 app 当成新应用，已授予的「辅助功能」权限随即
# 失效。改用一张固定证书后，TCC 绑定的是「证书 + bundle id」，授权一次就够。
# 证书由 scripts/setup-dev-cert.sh 生成，仅本机有效，不能用于分发。
DEV_CERT="TabFlick Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT"; then
    echo "▸ 使用开发证书签名（${DEV_CERT}）…"
    codesign --force --deep --sign "$DEV_CERT" "$APP"
else
    echo "▸ ad-hoc 签名（未找到开发证书，跑 scripts/setup-dev-cert.sh 可让授权稳定）…"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "  签名校验通过"

echo "▸ 打包 DMG…"
cp -R "$APP" "$DMG_STAGE/TabFlick.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp packaging/DMG-README.txt "$DMG_STAGE/请先阅读 Read Me First.txt"

hdiutil create -volname "TabFlick $VERSION" \
    -srcfolder "$DMG_STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$DMG_STAGE"

# --install：直接替换 /Applications 里的版本，省掉手动拖拽
if [[ " $* " == *" --install "* ]]; then
    echo "▸ 安装到 /Applications…"
    # 先请正在运行的实例退出，否则替换的是一个正被使用的 bundle
    if pgrep -f "/Applications/TabFlick.app/Contents/MacOS/TabFlick" >/dev/null; then
        osascript -e 'tell application "TabFlick" to quit' 2>/dev/null || true
        for _ in $(seq 1 20); do
            pgrep -f "/Applications/TabFlick.app/Contents/MacOS/TabFlick" >/dev/null || break
            sleep 0.25
        done
        pkill -f "/Applications/TabFlick.app/Contents/MacOS/TabFlick" 2>/dev/null || true
        sleep 0.5
    fi
    # rm 在前：cp -R 到已存在的目录是「拷进去」而不是「替换」，
    # 会把新 app 嵌套进旧 app 内部（PasteMemo beta.6 就是这么发出去的）
    rm -rf /Applications/TabFlick.app
    cp -R "$APP" /Applications/TabFlick.app
    # 下载来的包才有 quarantine，本地构建没有；这里防的是从 DMG 拷过来的情况
    xattr -dr com.apple.quarantine /Applications/TabFlick.app 2>/dev/null || true
    echo "  已安装：/Applications/TabFlick.app"
    open -a /Applications/TabFlick.app
    echo "  已启动"
fi

echo
echo "✅ 完成"
echo "   app : $APP"
echo "   dmg : $DMG ($(du -h "$DMG" | cut -f1))"
echo
echo "验包："
echo "   lipo -archs '$APP/Contents/MacOS/TabFlick'"
echo "   defaults read '$APP/Contents/Info.plist' CFBundleShortVersionString"
