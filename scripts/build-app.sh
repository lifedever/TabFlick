#!/bin/bash
# 构建 TabFlick.app 并打成 DMG（arm64 / x86_64 各一个包，与 PasteMemo 同款双包模式）。
#
#   ./scripts/build-app.sh            # 版本号取自最近的 git tag
#   ./scripts/build-app.sh 0.2.0      # 显式指定
#
# 产物：build/<arch>/TabFlick.app 和 build/TabFlick-<版本>-<arch>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

BUILD_DIR="$ROOT/build"
ARCHS=(arm64 x86_64)

# 开头就把所有中间产物清干净。脚本随时可能被 Ctrl+C 打断，只靠结尾清理
# 会留下暂存目录；下次 `cp -R src dst` 遇到已存在的 dst 语义是「拷进去」
# 而不是「替换」，结果是新 app 被嵌套进旧 app 里发出去。
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 优先用本机的开发证书。
#
# ad-hoc 签名（--sign -）的 TCC 记录绑定 cdhash，而 cdhash 随代码变化 ——
# 每次重新构建，macOS 都会把 app 当成新应用，已授予的「辅助功能」权限随即
# 失效。改用一张固定证书后，TCC 绑定的是「证书 + bundle id」，授权一次就够。
# 证书由 scripts/setup-dev-cert.sh 生成，仅本机有效，不能用于分发。
DEV_CERT="TabFlick Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT"; then
    SIGN_ID="$DEV_CERT"
    echo "▸ 将使用开发证书签名（${DEV_CERT}）"
else
    SIGN_ID="-"
    echo "▸ 将使用 ad-hoc 签名（未找到开发证书，跑 scripts/setup-dev-cert.sh 可让授权稳定）"
fi

[ -f assets/TabFlick.icns ] || ./scripts/make-icon.sh

build_one() {
    local arch="$1"
    local app="$BUILD_DIR/$arch/TabFlick.app"
    local dmg="$BUILD_DIR/TabFlick-$VERSION-$arch.dmg"
    local stage="$BUILD_DIR/dmg-$arch"

    echo "▸ [$arch] 编译…"
    (cd helper && swift build -c release --arch "$arch")
    # 单架构构建的产物在 .build/<triple>/release；.build/release 只是指向
    # 「最近一次构建」的符号链接，连续构建两个架构时它会来回切，不能用
    local bin_dir="$ROOT/helper/.build/$arch-apple-macosx/release"

    echo "▸ [$arch] 组装 bundle…"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_dir/tabflick" "$app/Contents/MacOS/TabFlick"
    sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
        packaging/Info.plist > "$app/Contents/Info.plist"
    cp assets/TabFlick.icns "$app/Contents/Resources/TabFlick.icns"

    # SPM 的 .process 资源会生成 {Package}_{Target}.bundle。必须用 glob 而
    # 不是写死名字：漏拷一个就是运行时 Bundle.module 直接 SIGTRAP，
    # 而且崩溃点离这里很远。
    shopt -s nullglob
    for bundle in "$bin_dir"/*.bundle; do
        [ -d "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
    done
    shopt -u nullglob

    codesign --force --deep --sign "$SIGN_ID" "$app"
    codesign --verify --strict "$app" && echo "  [$arch] 签名校验通过"

    echo "▸ [$arch] 打包 DMG…"
    mkdir -p "$stage"
    cp -R "$app" "$stage/TabFlick.app"
    ln -s /Applications "$stage/Applications"
    cp packaging/DMG-README.txt "$stage/请先阅读 Read Me First.txt"
    hdiutil create -volname "TabFlick $VERSION" \
        -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
    rm -rf "$stage"
}

for arch in "${ARCHS[@]}"; do
    build_one "$arch"
done

# --install：把本机架构的包直接替换 /Applications 里的版本，省掉手动拖拽
if [[ " $* " == *" --install "* ]]; then
    NATIVE_ARCH="$(uname -m)"
    APP="$BUILD_DIR/$NATIVE_ARCH/TabFlick.app"
    # ${} 必须写全：$VAR 后紧跟全角括号时 bash 会把多字节字符并进变量名，
    # set -u 下直接 unbound variable 中止（Coloplast 发布脚本踩过同款）
    echo "▸ 安装到 /Applications（${NATIVE_ARCH}）…"
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
for arch in "${ARCHS[@]}"; do
    dmg="$BUILD_DIR/TabFlick-$VERSION-$arch.dmg"
    echo "   $arch : $dmg ($(du -h "$dmg" | cut -f1))"
done
echo
echo "验包："
for arch in "${ARCHS[@]}"; do
    echo "   lipo -archs '$BUILD_DIR/$arch/TabFlick.app/Contents/MacOS/TabFlick'   # 应只有 $arch"
done
echo "   defaults read '$BUILD_DIR/arm64/TabFlick.app/Contents/Info.plist' CFBundleShortVersionString"
