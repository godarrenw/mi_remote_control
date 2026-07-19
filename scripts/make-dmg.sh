#!/bin/bash
# make-dmg.sh — 把 dist/MiRemote.app 组装成可分发的 DMG。
#
# 产物：dist/MiRemote-<version>.dmg
# 卷内容：MiRemote.app + 指向 /Applications 的软链 + README.txt（纯文本安装说明）
# 卷名：MiRemote
#
# 用法：
#   scripts/make-dmg.sh              # 需要已签名的 dist/MiRemote.app（正式流程）
#   scripts/make-dmg.sh --unsigned   # 允许 app 无有效签名（开发预览，产物名带 -unsigned）
#
# 正式打包默认要求 app 已用固定证书签名（见 scripts/package.sh）；--unsigned 是显式降级，
# 仅供本机 CLI 二进制装的预览包验证管道用，不要拿去分发。

set -euo pipefail
cd "$(dirname "$0")/.."

DIST="dist"
APP="$DIST/MiRemote.app"
VOL_NAME="MiRemote"

ALLOW_UNSIGNED=0
[ "${1:-}" = "--unsigned" ] && ALLOW_UNSIGNED=1

[ -d "$APP" ] || { echo "❌ 找不到 $APP，先跑 scripts/package.sh（或 --unsigned 预览需自行放置 .app）" >&2; exit 1; }

# ---- 签名闸门：正式流程要求有效签名；--unsigned 显式跳过 ----
# check_dr <app路径>：Designated Requirement 必须锚定 certificate leaf 且不含 cdhash。
# codesign --verify --strict 对 ad-hoc 签名同样放行——单靠它不够，正式通道必须查 DR，
# 否则 package.sh --unsigned 产物可被无参 make-dmg 包装成不带 -unsigned 的"正式"DMG。
check_dr() {
    local dr
    local bid
    local cert_tmp
    local app_cert_sha
    local keychain_cert_sha
    dr="$(codesign -d -r- "$1" 2>&1 | grep '^designated' || true)"
    if ! echo "$dr" | grep -q 'certificate leaf'; then
        echo "❌ 错误：$1 的 DR 未锚定 certificate leaf（当前: ${dr:-<空>}）。" >&2
        echo "   疑似 ad-hoc/未签名 app——正式 DMG 拒绝打包；开发预览请用 --unsigned。" >&2
        return 1
    fi
    if echo "$dr" | grep -q 'cdhash'; then
        echo "❌ 错误：$1 的 DR 含 cdhash——重编译必掉 TCC 授权，正式 DMG 拒绝打包。" >&2
        return 1
    fi
    bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$bid" != "com.miremote.controller" ]; then
        echo "❌ 错误：bundle id 漂移（当前: ${bid:-<空>}）。" >&2
        return 1
    fi
    # “有 certificate leaf”还不够：另一张证书重签也会让 TCC 身份变化。
    # 精确比较 app 叶证书与钥匙串固定 MiRemote Dev 证书的 DER SHA-256。
    cert_tmp="$(mktemp -d)"
    if ! codesign -d --extract-certificates "$cert_tmp/app-cert" "$1" >/dev/null 2>&1 \
        || [ ! -f "$cert_tmp/app-cert0" ]; then
        echo "❌ 错误：无法提取 app 叶证书。" >&2
        rm -rf "$cert_tmp"
        return 1
    fi
    app_cert_sha="$(shasum -a 256 "$cert_tmp/app-cert0" | awk '{print $1}')"
    if ! security find-certificate -c "MiRemote Dev" -p 2>/dev/null \
        | openssl x509 -outform DER > "$cert_tmp/keychain-cert.der" 2>/dev/null; then
        echo "❌ 错误：钥匙串中找不到固定 MiRemote Dev 证书。" >&2
        rm -rf "$cert_tmp"
        return 1
    fi
    keychain_cert_sha="$(shasum -a 256 "$cert_tmp/keychain-cert.der" | awk '{print $1}')"
    rm -rf "$cert_tmp"
    if [ -z "$app_cert_sha" ] || [ "$app_cert_sha" != "$keychain_cert_sha" ]; then
        echo "❌ 错误：app 并非由钥匙串中的固定 MiRemote Dev 证书签名。" >&2
        return 1
    fi
    return 0
}

if [ "$ALLOW_UNSIGNED" = "0" ]; then
    if ! codesign --verify --strict "$APP" 2>/dev/null; then
        echo "❌ 错误：$APP 签名无效。正式 DMG 必须打包已签名的 app。" >&2
        echo "   先跑 scripts/package.sh 生成签名 app；开发预览可用 --unsigned 显式降级。" >&2
        exit 1
    fi
    check_dr "$APP" || exit 1
else
    echo "⚠️  --unsigned：跳过签名校验，产物仅供开发预览，切勿分发。"
fi

# ---- 版本号（与 package.sh 一致，从 git 生成） ----
SHORT_VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")"
SUFFIX=""
[ "$ALLOW_UNSIGNED" = "1" ] && SUFFIX="-unsigned"
DMG="$DIST/MiRemote-$SHORT_VERSION$SUFFIX.dmg"

echo "-- 版本: $SHORT_VERSION"
echo "-- 目标: $DMG"

# ---- 组装临时卷根目录 ----
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/MiRemote.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<'TXT'
MiRemote 安装说明
==================

1. 把 MiRemote.app 拖到本窗口里的「Applications」文件夹。

2. 首次打开：在「应用程序」里右键（或按住 Control 点击）MiRemote.app
   → 打开 → 再点「打开」。直接双击会因为没有 Apple 公证而被拦，属正常。
   如果仍被拦，去「系统设置 → 隐私与安全性」页面底部点「仍要打开」。

3. 按 App 的向导授予「蓝牙」「输入监控」「辅助功能」三项权限。

语音打字需要额外安装 BlackHole 2ch 虚拟声卡与豆包输入法，详见项目 README。

项目主页：https://github.com/USER/miremote
TXT

# ---- hdiutil 生成压缩只读 DMG ----
rm -f "$DMG"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo "✅ 完成: $DMG"
