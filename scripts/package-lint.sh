#!/bin/bash
# package-lint.sh — 验证 scripts/package.sh 的产物 .app 是否合格。
#
# 检查项：
#   1. codesign --verify --strict 通过
#   2. Designated Requirement 锚定 certificate leaf（非 cdhash）
#   3. plutil -lint Info.plist 通过 + 关键字段存在
#   4. 主可执行文件存在且可执行
#   5. zip 往返（ditto 解压）后签名仍有效
#   6. DR 一致性：重新跑一次 package.sh（重编译+重签名），两次 DR 输出必须逐字一致
#      —— 这是 "TCC 授权跨重编译存活" 的静态等价判据（codex-phase0 必查项）
#
# 用法：scripts/package-lint.sh [app路径]   （缺省 dist/MiRemote.app）
#       SKIP_DR_CONSISTENCY=1 可跳过第 6 项（避免二次全量构建）

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/MiRemote.app}"
FAIL=0
note() { echo "  $1"; }
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1" >&2; FAIL=1; }

[ -d "$APP" ] || { echo "❌ 找不到 $APP，先跑 scripts/package.sh" >&2; exit 1; }

# 1. 签名验证
if codesign --verify --strict --verbose=2 "$APP" 2>/dev/null; then
    pass "codesign --verify --strict"
else
    fail "codesign --verify --strict"
fi

# 2. DR 锚定证书
DR1="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
if echo "$DR1" | grep -q 'certificate leaf'; then
    pass "DR 锚定 certificate leaf"
    note "$DR1"
else
    fail "DR 未锚定 certificate leaf（当前: ${DR1:-<空>}）"
fi
if echo "$DR1" | grep -q 'cdhash'; then
    fail "DR 含 cdhash——重编译必掉 TCC 授权"
fi

# 3. Info.plist
PLIST="$APP/Contents/Info.plist"
if plutil -lint "$PLIST" >/dev/null 2>&1; then
    pass "plutil -lint Info.plist"
else
    fail "plutil -lint Info.plist"
fi
for KEY in CFBundleIdentifier NSBluetoothAlwaysUsageDescription LSMinimumSystemVersion CFBundleVersion; do
    if /usr/libexec/PlistBuddy -c "Print :$KEY" "$PLIST" >/dev/null 2>&1; then
        pass "Info.plist 含 $KEY ($(/usr/libexec/PlistBuddy -c "Print :$KEY" "$PLIST"))"
    else
        fail "Info.plist 缺 $KEY"
    fi
done
BID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST" 2>/dev/null || true)"
[ "$BID" = "com.miremote.controller" ] && pass "bundle id 固定 com.miremote.controller" \
    || fail "bundle id 漂移: $BID"

# 4. 主可执行
BIN="$APP/Contents/MacOS/miremote"
if [ -x "$BIN" ] && file "$BIN" | grep -q 'Mach-O'; then
    pass "主可执行存在且为 Mach-O 可执行"
else
    fail "主可执行缺失/不可执行"
fi

# 5. zip 往返后签名仍有效
ZIP="$(ls -t dist/MiRemote-*.zip 2>/dev/null | head -1 || true)"
if [ -n "$ZIP" ]; then
    RT="$(mktemp -d)"
    ditto -x -k "$ZIP" "$RT"
    if codesign --verify --strict "$RT/MiRemote.app" 2>/dev/null; then
        pass "zip 往返后签名有效 ($ZIP)"
    else
        fail "zip 往返后签名失效 ($ZIP)"
    fi
    rm -rf "$RT"
else
    fail "找不到 dist/MiRemote-*.zip"
fi

# 6. DR 一致性：重编译+重签名后 DR 必须逐字不变
if [ "${SKIP_DR_CONSISTENCY:-0}" = "1" ]; then
    note "跳过 DR 一致性检查 (SKIP_DR_CONSISTENCY=1)"
else
    echo "-- DR 一致性：二次构建对比 codesign -d -r- ..."
    ./scripts/package.sh >/dev/null
    DR2="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
    if [ -n "$DR1" ] && [ "$DR1" = "$DR2" ]; then
        pass "两次构建 DR 逐字一致（TCC 授权可跨重编译存活）"
    else
        fail "两次构建 DR 不一致："
        note "第一次: $DR1"
        note "第二次: $DR2"
    fi
fi

if [ "$FAIL" = "0" ]; then
    echo "✅ package-lint 全部通过"
else
    echo "❌ package-lint 存在失败项" >&2
fi
exit "$FAIL"
