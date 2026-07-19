# 参与贡献

欢迎给 MiRemote 提 Issue 和 PR。项目很小、零第三方依赖，上手门槛低。

## 构建环境

只需要 macOS 14+ 和 **Command Line Tools**（`xcode-select --install`），不用装完整
Xcode。CLT 自带的 Swift 6 就能编译。

```bash
./build.sh                 # 直接用 swiftc 编译到 .build/miremote
.build/miremote --self-test   # 跑内置自检（80+ 项，应全绿）
.build/miremote --ui-preview  # 只看 GUI，不启动蓝牙/HID
.build/miremote --doctor      # 环境体检
```

> 用 `./build.sh` 而不是 `swift build`：CLT 不带 XCTest/Swift Testing，测试是编进
> 二进制、用 `--self-test` 跑的；`build.sh` 还会用 `-sectcreate` 把 Info.plist
> 嵌进二进制（CLI 用 CoreBluetooth 必需）。

改动运行时行为后，请确保 `--self-test` 仍然全绿。

## 代码风格

跟着现有代码走：四空格缩进、类型和协议用大驼峰、其余小驼峰；模块边界通过
`App/Contracts.swift` 里的契约类型交互。注释只写「为什么」，不写「做了什么」。

## 提交 PR

1. 从 `main` 切分支，一个 PR 只做一件事。
2. 本地 `./build.sh && .build/miremote --self-test` 通过。
3. 若改了打包/签名，跑 `bash -n scripts/*.sh` 确认脚本语法无误。
4. 描述里写清动机和实机验证方式（这个项目大量行为只能在真机上验证，欢迎附上
   你在 `FIELD-TEST.md` 清单上的结果）。
