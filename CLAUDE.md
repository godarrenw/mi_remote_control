# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MiRemote：小米蓝牙遥控器 2 Pro → macOS 全能控制台。Swift 6，零第三方依赖，单一可执行目标同时是 CLI 和 GUI（SwiftUI）。

## 构建与测试

```bash
./build.sh                       # swiftc 直编 → .build/miremote（RELEASE=1 开 -O）
.build/miremote --self-test      # 全部测试（唯一测试入口，必须全绿）
.build/miremote --ui-preview     # 只起 GUI，不装 hidutil 映射、不抢键盘、不连蓝牙
.build/miremote --doctor         # 环境体检 + 残留清理（只读子命令，不受单实例锁限制）
.build/miremote --verbose --keys --doubao   # CLI 服务模式：完整跑按键+语音，盯日志
.build/miremote --run-action '{"type":"key_stroke","key":"return"}'   # 单条动作冒烟
bash -n scripts/*.sh             # 改了打包脚本后的语法闸门
```

**不要用 `swift build`。** `Package.swift` 只用于表达目录布局；Command Line Tools 不带
XCTest/Swift Testing，所以测试是**编进二进制**、用 `--self-test` 跑的。`build.sh` 还用
`-sectcreate` 把 `Resources/Info-cli.plist` 嵌进 `__TEXT`——CLI 二进制没有 bundle，
缺这个 plist 时 TCC 会在用 CoreBluetooth 的瞬间直接杀进程。

### 跑/加单个测试

`SelfTest.run()`（`Sources/MiRemote/App/SelfTest.swift`）是一条顺序执行的 `expect(...)` 流水，
**没有按名字跑单测的机制**。新增测试的两种方式：

- 纯逻辑、属于某个模块 → 在该模块里加 `static func selfCheck() -> Bool`（见
  `MappingEngine` / `ActionRunner` / `WorkspaceActions` / `OverlayCenter` / `RemoteDiagram`），
  再在 `SelfTest.run()` 里加一行 `expect(X.selfCheck(), "...")`。
- 一次性断言 → 直接在 `SelfTest.run()` 里加 `do { ... expect(...) }` 块。

`MappingEngine` 的时序测试用注入的 `ManualClock`（`schedule`/`advance`）做确定性推进，
不要在测试里用真实 sleep。

## 架构

### 两条互不干扰的 BLE 通道

遥控器在同一条链路上同时暴露标准 HID（按键，系统接管）与 ATVV 私有 GATT（语音，系统不认）。
两条链路在代码里完全独立，**互相不能有依赖**：

```
按键：hidutil 内核重映射 → 中转键 → CGEventTap 捕获吞掉 → RemoteKey
      → MappingEngine（层/tap/hold/double/手势/per-app） → Action → ActionRunner
语音：ATVVBridge（CoreBluetooth 状态机） → ADPCMDecoder → PCMSink
      → AudioBridge（AVAudioEngine） → BlackHole 2ch → 输入法出字
```

### 按键接管的三条铁律（实机换来的，别回退）

1. **macOS 禁止用户态 seize 蓝牙 HID 键盘**（`0xE00002C1`）。历史上 `HIDEngine` 先试
   seize 再降级重开，导致 IOHID 回调永远零事件。现在是纯监听模式，**不要重新引入 seize 路径**。
2. 有副作用的键先经 `hidutil` 重映射到系统零默认行为的中转键（F13–F20 / 小键盘 Clear·除·乘，
   表在 `HID/KeyRemapper.swift`），再由 `CGEventTap` 反查回 `RemoteKey`。F21–F24 在 macOS
   没有虚拟键码，映过去不产事件，不可用。
3. **返回键 usage `0xF1` 不进 hidutil 表**（超出标准键盘 usage 范围，系统本来就忽略它），
   它走 `HIDEngine` 的 IOHID 监听通道直接读——这是唯一还在用 IOHID 的键。

方向键在 `TapEngine` 里按 `MappingEngine` 的快照三态分流：纯原生场景就地改写回方向键
keycode 放行（保住系统 autorepeat 与零延迟），层/手势场景才吞掉喂引擎。

进程退出必须清空 hidutil 映射，否则污染真键盘（`hidutil property --set '{"UserKeyMapping":[]}'` 可手动恢复）。

### 基础态（层 0）的按键保护

DESIGN §3.1b 的「内容操作」原则：基础态方向=光标、返回=删除、OK=确认，profile 不得改写。
实现在 `MappingEngine.fireTap` / `doubleAction` / `publishTapRoute`，**不是**普通的绑定查表——
改这里前先读 `overlayDeclared` 的注释。

唯一例外是 **OK 的短按**：per-app profile 显式声明时放行（语义仍是「确认/发送」，
只是换了发送键，如飞书的 ⌘+Enter），`global` 与继承值仍被挡下。
方向键与返回键不放行——内置预设（Ghostty/浏览器/微信…）的 base 槽里躺着 `back=Esc`、
`左右=切标签` 一类历史绑定，一旦放行会让文字输入态突然删不了字、移不了光标；
这些 App 专属动作的正确归属是控制模式 `layers["2"]`。
放行范围若变动，`HintBarCatalog.hints(forBaseProfile:)` 要同步扩充，
否则提示条会许诺引擎不认的绑定。

### 模块契约

`App/Contracts.swift` 是冻结的模块边界：`RemoteKey`（13 键 usage 实测表）、`ButtonEvent`、
`Action` / `MacroStep` / `KeyBinding` / `MappingConfig` 的 Codable 模型、以及 `PCMSink` /
`HIDEngineDelegate` / `MappingEngineDelegate` / `ATVVBridgeDelegate` / `ActionRunning` 协议。
跨模块改动从这里开始。`Action` 的解码是**严格**的：未知 `type` 抛错而非静默降级，
拼写错误在加载配置时就暴露。

### 接线中枢

`App/AppServices.swift` 是 CLI 与 GUI 共用的服务容器（`start()` / `stop()` / `applyConfig`），
内含 `ConfigStore`、配置迁移、`VoiceBridgeApp`（语音链路）、`KeyMapperApp`（按键链路 + 前台 App
MRU）。`App/main.swift` 只做参数解析、单实例锁与 CLI/GUI 分流；GUI 走 `UI/GUIAppDelegate.swift`。

单实例锁在**参数解析之后**获取：`--help` / `--doctor` / `--self-test` / `--login-item status`
等只读子命令必须能在 GUI 运行时随时执行，不得争用 hidutil / CGEventTap。

浮层（窗口选择器 / 系统功能菜单 / 教程 / App 轮盘，均在 `UI/OverlayCenter.swift`）打开时，
`MappingEngine.setOverlayCapture` 把遥控键路由给浮层而非动作——这是 uiCapture 路由态。
长按菜单键 1.5s 是硬编码逃生键，强制清空所有层/模式/浮层，不受配置影响。

### 配置与迁移

`~/Library/Application Support/MiRemote/config.json`，`MappingConfig.currentVersion` 当前为 **8**。
改默认配置语义时：`currentVersion` +1，并在 `AppServices.swift` 的 `migrateConfigIfNeeded`
里加迁移分支（现有迁移只改内置支持 App 的 profile，**不改写用户自建 profile**）。
优先级恒为 **CLI 标志 > config.json > 内置默认**。

## 打包与签名

```bash
./scripts/setup-signing.sh   # 一次性：创建固定自签证书 "MiRemote Dev"
./scripts/package.sh         # → dist/MiRemote.app + zip
./scripts/make-dmg.sh        # → dist/MiRemote-<ver>.dmg
./scripts/package-lint.sh    # 验签 / DR / plist / zip 往返 / DR 二次构建一致性
./scripts/package-test.sh    # ad-hoc 测试包，仅用于本机实机验收
```

签名策略不可动摇：固定证书 `MiRemote Dev` + 固定 bundle id `com.miremote.controller`，
使 Designated Requirement 锚定 certificate leaf 而非 cdhash——**TCC 授权才能跨重编译存活**。
缺证书时 `package.sh` 硬失败，**绝不静默回退 ad-hoc**（`--unsigned` 只给无证书的 CI 用）。

CI（`.github/workflows/ci.yml`，macos-26）= `./build.sh` + `--self-test`，FAIL 行转成
`::error::` 注解以便匿名读取。打 `v*` tag 触发 `release.yml` 自动出 ad-hoc DMG/zip Release。

## 约定

- 注释与提交信息用中文；注释只写「为什么」，不写「做了什么」。四空格缩进。
- 大量行为只能实机验证。改了运行时行为后至少跑通 `./build.sh && .build/miremote --self-test`；
  涉及 TCC / 蓝牙弹窗 / 撤权恢复的改动需在打包 `.app` 上人工验收（见 `FIELD-TEST.md`、
  `TESTPLAN.md` 的「回归红线」与「回归冒烟清单 Top 15」）。
- 调试工具在 `tools/`（`hidprobe` usage 探针、`rawdump`、`eventmon`、`taptest`），单文件
  swiftc 直编即可。
- **文档新鲜度**：`DESIGN.md` 是 v1 立项设计，§2 的文件地图已与实际不符（`ProfileManager.swift`
  / `KeyStroke.swift` / `MainWindow.swift` 等从未落地）——原理章节（§1 蓝牙/ATVV 时序、§3.1b
  心智模型、§4 动作实现）仍然有效，文件结构以 `HANDOFF.md` 与实际代码为准。

## 已知限制

- **Secure Input**：密码输入期间 CGEventTap 被系统旁路而 hidutil 映射仍生效，遥控器方向键会
  以中转键泄漏进前台（真键盘不受影响）。v1 接受；未来可轮询 `IsSecureEventInputEnabled()`
  在此期间临时卸载方向键映射。
- 未做 Apple 公证：每次升级需重新授予输入监控 / 辅助功能（配置不丢失）。
- 官方「小米遥控器助手」与本程序不能同时运行（抢 ATVV / HID）。
- BlackHole / 豆包输入法 / 具体 App 缺失时对应功能自动降级，按键映射不受影响。
