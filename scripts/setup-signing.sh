#!/bin/bash
# setup-signing.sh — 一次性创建 "MiRemote Dev" 自签名代码签名证书并导入登录钥匙串。
#
# 背景（见 scratchpad/tcc-signing.md）：
#   TCC 按签名的 Designated Requirement 认 App 身份。ad-hoc 签名 DR 锚定 cdhash，
#   重编译即失效；用固定证书签名后 DR = identifier + certificate leaf，跨重编译存活，
#   辅助功能/输入监控授权一次授予永久保留。
#
# 幂等：证书已存在则直接跳过创建。
# 本脚本自动完成 openssl 生成 + p12 打包 + 导入钥匙串；
# 剩余两步需要用户交互（GUI 设"始终信任" + partition list 输密码），脚本只给出指引。

set -euo pipefail

CERT_CN="MiRemote Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMPDIR_SIGN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SIGN"' EXIT

echo "== MiRemote 签名证书一次性安装 =="

# ---- 幂等检查：证书已可用于代码签名则直接退出 ----
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
    echo "✅ 证书 \"$CERT_CN\" 已存在且可用于代码签名，无需重复创建。"
    echo "   （如需重建：先在\"钥匙串访问\"里删除旧的 \"$CERT_CN\" 证书和私钥，再重跑本脚本）"
    exit 0
fi

# 证书在钥匙串里但尚未被信任（find-identity -v 查不到）的情况：跳过创建，只提示信任步骤
if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "⚠️  钥匙串里已有 \"$CERT_CN\" 证书，但尚未被信任用于代码签名。"
    echo "   跳过创建，请直接完成下方【手动步骤 1】设为始终信任。"
else
    echo "-- 1/3 生成 10 年有效期自签名代码签名证书（openssl）"
    openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
        -keyout "$TMPDIR_SIGN/miremote-dev.key" -out "$TMPDIR_SIGN/miremote-dev.crt" \
        -subj "/CN=$CERT_CN" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=codeSigning"

    echo "-- 2/3 打包 p12（-legacy 必须：openssl 3.x 默认算法钥匙串导入会失败）"
    openssl pkcs12 -export -legacy \
        -in "$TMPDIR_SIGN/miremote-dev.crt" -inkey "$TMPDIR_SIGN/miremote-dev.key" \
        -out "$TMPDIR_SIGN/miremote-dev.p12" -passout pass:miremote

    echo "-- 3/3 导入登录钥匙串（-T /usr/bin/codesign：授权 codesign 使用私钥）"
    security import "$TMPDIR_SIGN/miremote-dev.p12" \
        -k "$KEYCHAIN" \
        -P miremote -T /usr/bin/codesign
    echo "✅ 证书已导入登录钥匙串。"
fi

cat <<'EOF'

========================================================================
还差两步需要你手动完成（一次性，之后 build/package 全自动）：

【手动步骤 1】把证书设为"始终信任"（GUI 操作）
  1. 执行:  open -a "Keychain Access"   （打开"钥匙串访问"）
  2. 左侧选"登录"钥匙串 → 找到证书 "MiRemote Dev" → 双击
  3. 展开"信任" → 把"代码签名 (Code Signing)"设为"始终信任"
  4. 关闭窗口，按提示输入登录密码确认
  （不做这步 codesign 会报 CSSMERR_TP_NOT_TRUSTED）

【手动步骤 2】设置钥匙串 partition list（终端执行，会交互式询问登录密码）
    security set-key-partition-list -S apple-tool:,apple: -s \
      ~/Library/Keychains/login.keychain-db
  （不做这步，每次 codesign 都会弹"允许访问钥匙串"对话框）

【验证】完成后执行：
  security find-identity -v -p codesigning
  应能看到 "MiRemote Dev"。然后即可运行 scripts/package.sh 打包。
========================================================================
EOF
