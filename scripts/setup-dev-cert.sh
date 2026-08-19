#!/bin/bash
# 生成一张本地自签名代码签名证书，供开发期签 TabFlick.app 用。
#
# 解决的问题：ad-hoc 签名（codesign --sign -）的 TCC 记录绑定 cdhash，
# 而 cdhash 随代码变化。于是每次重新构建，macOS 都把 app 当成一个新应用，
# 已授予的「辅助功能」权限随即失效 —— 开发期每天要重新授权十几次。
#
# 换成固定证书后，TCC 记录绑定的是「证书 + bundle identifier」，
# 代码怎么改都不影响，授权一次就够。
#
# 注意：这张证书只对本机有效，不能用于分发。分发仍需 Apple Developer ID。
set -euo pipefail

CERT_NAME="TabFlick Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 证书已存在：$CERT_NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# codesign 要求证书带 codeSigning 这个扩展用途，默认的自签名证书没有
cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = TabFlick Dev

[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

echo "▸ 生成自签名证书…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

echo "▸ 导入钥匙串…"
# 分别导入证书和私钥，不走 PKCS12：OpenSSL 3.x 生成的 p12 用 AES-256+SHA256，
# 而 macOS 的 security 只认老式的 SHA1 MAC，导入会报 "MAC verification failed"。
# 钥匙串会自己按公钥把两者配成一个 identity。
# -T /usr/bin/codesign：允许 codesign 直接使用私钥，免去每次签名弹授权框。
security import "$WORK/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security import "$WORK/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

# 让 codesign 无需交互即可访问私钥。这一步需要钥匙串密码，
# 失败也不致命 —— 只是签名时会弹一次授权框，点「始终允许」即可。
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
    echo "  （未能自动授权私钥，首次签名时点「始终允许」即可）"

echo
# 这里同样不能加 -v：自签名证书没有可信任的颁发链，会被 -v 过滤掉。
# 这不影响 codesign 使用它 —— 只是 Gatekeeper 不认，本机开发用足够。
security find-identity -p codesigning | grep "$CERT_NAME" || true
echo "✅ 完成。之后 build-app.sh 会自动使用这张证书签名。"
