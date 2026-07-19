#!/bin/zsh
# ponytail: swiftc 直编绕开本机损坏的 SwiftPM manifest 链接；CLT 修好后可回归 swift build
set -e
cd "$(dirname "$0")"
mkdir -p .build
# -sectcreate 嵌入 Info.plist：CLI 二进制没有 bundle，蓝牙权限描述必须嵌进 __TEXT 段，否则 TCC 直接杀进程
swiftc ${RELEASE:+-O} -o .build/miremote \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Info-cli.plist \
  Sources/MiRemote/App/*.swift \
  Sources/MiRemote/Bluetooth/*.swift \
  Sources/MiRemote/Audio/*.swift \
  Sources/MiRemote/Actions/*.swift \
  Sources/MiRemote/HID/*.swift \
  Sources/MiRemote/Mapping/*.swift \
  Sources/MiRemote/UI/*.swift
codesign -s - --force .build/miremote 2>/dev/null || true
echo "built .build/miremote"
