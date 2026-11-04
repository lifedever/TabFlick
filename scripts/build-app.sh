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

# SDK 版本必须显式喂给链接器（2026-09-15 踩）：Xcode 27 的 SwiftPM 把 SDK 路径
# 用 `--sysroot` 传给 clang，而这版 clang 只认 `-isysroot`（或 SDKROOT）来读
# SDK 版本，读不到就把 LC_BUILD_VERSION 的 sdk 写成部署目标 14.0。系统按这个
# 值判定 app「是按哪代 SDK 写的」—— 14.0 意味着整个 app 拿不到 macOS 26+ 的
# 外观（设置窗口的 toolbar 分页、菜单、控件全是旧样子）。编译、签名、打包
# 全程不报错。开发时的 swift run 同样要带（见 scripts/dev-run.sh）。
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
SWIFT_SDK_FLAGS=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH")

build_one() {
    local arch="$1"
    local app="$BUILD_DIR/$arch/TabFlick.app"
    local dmg="$BUILD_DIR/TabFlick-$VERSION-$arch.dmg"
    local stage="$BUILD_DIR/dmg-$arch"

    echo "▸ [$arch] 编译…"
    (cd helper && swift build -c release --arch "$arch" "${SWIFT_SDK_FLAGS[@]}")
    # 产物路径**必须问 SwiftPM 要，不能写死**（2026-09-15 踩）：Xcode 27 起
    # `--arch` 的产物落到 .build/out/Products/Release，老的
    # .build/<triple>/release 不再更新但**目录还留在原地** —— 写死那条路径会
    # 拷到上一次构建的陈旧产物，表现成「版本号是新的、代码是旧的」，编译、
    # 签名、打包全程不报错（同 PasteMemo beta.6 那类事故）。
    #
    # 两个架构返回的是同一个路径，所以必须编完一个立刻拷走（下面就是这个顺序），
    # 不能先把两个架构都编完再拷。
    local bin_dir
    bin_dir="$(cd helper && swift build -c release --arch "$arch" "${SWIFT_SDK_FLAGS[@]}" --show-bin-path)"
    [ -f "$bin_dir/tabflick" ] || { echo "✗ [$arch] 找不到产物：$bin_dir/tabflick"; exit 1; }

    # 防线：产物记录的 SDK 版本必须是本机 SDK，不能退化成部署目标（14.0）。
    # 这个值决定系统给不给 macOS 26+ 的外观，错了不报错、只是整个 app 长得旧。
    local linked_sdk
    linked_sdk=$(otool -l "$bin_dir/tabflick" | awk '/LC_BUILD_VERSION/{f=1} f&&/sdk/{print $2; exit}')
    if [ "${linked_sdk%%.*}" -lt 26 ] 2>/dev/null || [ -z "$linked_sdk" ]; then
        echo "✗ [$arch] 产物链接的 SDK 是 ${linked_sdk:-未知}，不是本机 SDK（$(basename "$SDK_PATH")）"
        exit 1
    fi

    # 防线：只要还有源码比产物新，就说明这次构建没真的覆盖到，直接停。
    # 这类问题唯一的症状就是「改了没生效」，不拦住就得等上线后才发现。
    local stale_src
    stale_src=$(find helper/Sources -name '*.swift' -newer "$bin_dir/tabflick" -print -quit)
    if [ -n "$stale_src" ]; then
        echo "✗ [$arch] 源码比产物新（$stale_src），构建没生效"
        exit 1
    fi

    echo "▸ [$arch] 组装 bundle…"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_dir/tabflick" "$app/Contents/MacOS/TabFlick"
    sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
        packaging/Info.plist > "$app/Contents/Info.plist"
    cp assets/TabFlick.icns "$app/Contents/Resources/TabFlick.icns"

    # 扩展随 app 带一份（ExtensionUpdater）：设置 → 浏览器 →「安装扩展」从这里拷到固定目录让用户装；
    # 连上的扩展比它旧时，app 把扩展加载的那个文件夹换成这份、通知它重载。开发文件不进包，同扩展 zip。
    cp -R extension "$app/Contents/Resources/Extension"
    rm -rf "$app/Contents/Resources/Extension/tests"
    find "$app/Contents/Resources/Extension" -name .DS_Store -delete
    [ -f "$app/Contents/Resources/Extension/manifest.json" ] || { echo "❌ [$arch] app 里没带上扩展"; exit 1; }

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

# 扩展 zip。官网「扩展下载」固定指向
#   releases/latest/download/TabFlick-Extension.zip
# 资产名和 DMG 命名一样是契约：改名 = 官网链接 404。
echo "▸ 打包扩展 zip…"
EXT_STAGE="$BUILD_DIR/ext-stage"
rm -rf "$EXT_STAGE"
mkdir -p "$EXT_STAGE"
cp -R extension "$EXT_STAGE/TabFlick-Extension"
# 只留 Chrome 真正会加载的东西：manifest 里没引用的开发文件（测试等）
# 混进去，用户解压后会看到一堆不知道干嘛的东西。用**排除清单**而不是
# 白名单拷贝 —— 新增运行时文件（新 js、新图标）时不会被悄悄漏掉。
rm -rf "$EXT_STAGE/TabFlick-Extension/tests"
(cd "$EXT_STAGE" && zip -qr "$BUILD_DIR/TabFlick-Extension.zip" TabFlick-Extension -x "*.DS_Store")
rm -rf "$EXT_STAGE"

# 自检：manifest 引用的文件必须都在包里，包里不该有 manifest 之外的 .js
missing=$(unzip -l "$BUILD_DIR/TabFlick-Extension.zip" | grep -c "manifest.json")
[ "$missing" -eq 1 ] || { echo "❌ 扩展 zip 里没有 manifest.json"; exit 1; }
if unzip -l "$BUILD_DIR/TabFlick-Extension.zip" | grep -qE "/(tests|checks|node_modules)/"; then
    echo "❌ 扩展 zip 混入了开发文件"; exit 1
fi

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
