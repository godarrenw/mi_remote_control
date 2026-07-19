#!/bin/bash
# package.sh — 组装并签名 MiRemote.app，产出可分发 zip。
#
# 产物：dist/MiRemote.app + dist/MiRemote-<version>.zip
#
# 签名策略（见 scratchpad/tcc-signing.md + codex-phase0 [TCC/代码签名]）：
#   - 必须用固定自签证书 "MiRemote Dev" 签名（DR 锚定 certificate leaf，TCC 授权跨重编译存活）。
#   - 证书不存在 → 硬失败退出，绝不回退 ad-hoc（ad-hoc DR 锚 cdhash，每次重编译掉权限）。
#   - 不加 --options runtime：无公证场景 Hardened Runtime 无收益且可能干扰
#     （tcc-signing.md §3.2：纯本机/小范围分发可省略）。
#   - 嵌套代码从内到外签，不用已弃用的 --deep。当前 bundle 只有主可执行文件
#     （签 bundle 时会一并签入），将来引入 framework/helper 时先逐个签内层。

set -euo pipefail
cd "$(dirname "$0")/.."

CERT_CN="MiRemote Dev"
BUNDLE_ID="com.miremote.controller"   # 固定不变——DR 的一半，改了就掉 TCC 授权
DIST="dist"
APP="$DIST/MiRemote.app"

# ---- 0. 证书检查：缺证书硬失败，绝不 ad-hoc 回退 ----
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
    echo "❌ 错误：找不到可用的代码签名证书 \"$CERT_CN\"。" >&2
    echo "" >&2
    echo "   MiRemote 必须用固定证书签名，否则 TCC 权限（辅助功能/输入监控）" >&2
    echo "   每次重编译都会失效。禁止回退 ad-hoc 签名。" >&2
    echo "" >&2
    echo "   请先执行一次性初始化：" >&2
    echo "     ./scripts/setup-signing.sh" >&2
    echo "   并按提示完成\"始终信任\"与 partition list 两个手动步骤。" >&2
    exit 1
fi

# ---- 1. 构建 release 二进制 ----
echo "-- 构建 release 二进制"
RELEASE=1 ./build.sh

# ---- 2. 版本号：从 git 生成 ----
SHORT_VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")"
BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
echo "-- 版本: $SHORT_VERSION (build $BUILD_VERSION)"

# ---- 3. 组装 .app ----
echo "-- 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

sed -e "s/@SHORT_VERSION@/$SHORT_VERSION/" \
    -e "s/@BUILD_VERSION@/$BUILD_VERSION/" \
    Resources/Info-app.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

cp .build/miremote "$APP/Contents/MacOS/miremote"
chmod +x "$APP/Contents/MacOS/miremote"

# 默认配置（如仓库提供）；运行时缺省会在 ~/Library/Application Support/MiRemote/ 自动生成
if [ -f "Resources/default-config.json" ]; then
    cp Resources/default-config.json "$APP/Contents/Resources/"
fi

# ---- 4. 签名（从内到外；当前无嵌套 framework/helper，签 bundle 即含主可执行） ----
echo "-- 签名（证书: $CERT_CN, identifier: $BUNDLE_ID）"
codesign --force \
    --identifier "$BUNDLE_ID" \
    --sign "$CERT_CN" \
    "$APP"

# 自检：DR 必须锚定 certificate leaf（而非 cdhash），否则 TCC 跨重编译存活失效
DR="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
if ! echo "$DR" | grep -q 'certificate leaf'; then
    echo "❌ 错误：签名后的 Designated Requirement 未锚定 certificate leaf：" >&2
    echo "   $DR" >&2
    echo "   TCC 授权将无法跨重编译存活。检查证书是否已设\"始终信任\"。" >&2
    exit 1
fi
echo "   DR: $DR"
codesign --verify --strict "$APP"

# ---- 5. 打 zip（ditto 保留签名/扩展属性） ----
ZIP="$DIST/MiRemote-$SHORT_VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ 完成: $APP"
echo "✅ 分发包: $ZIP"
