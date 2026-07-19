# 交接文档（2026-07-19）

## 项目
小米蓝牙遥控器 2 Pro（VID 0x2717 / PID 0x32B8，13 键，无静音键）→ macOS 全能控制台。
Swift 6 / SwiftPM 布局 / 零第三方依赖。设计文档 `DESIGN.md`，测试清单 `TESTPLAN.md`，UI 定稿 `mockups/v3-macos.html`（macOS 系统设置风，用户已确认）。

## 构建与运行

```bash
./build.sh                      # swiftc 直编（不要用 swift build，见下）
.build/miremote --self-test     # 14 项自检，全绿
.build/miremote --verbose --doubao --keys   # 完整运行（语音+按键）
```

- **不要用 `swift build` 跑测试**：CLT 不带 XCTest/Swift Testing，测试编进二进制用 `--self-test` 跑。
- build.sh 里 `-sectcreate` 嵌入 Info.plist（CLI 用 CoreBluetooth 必需）+ 自签。
- 本机 CLT 曾坏过一次（SDK/编译器错配），已重装 CLT 26.6 修复。
- 权限：需「输入监控」+「辅助功能」（`.build/miremote` 手动加入辅助功能列表；**每次重编译后临时签名变化，可能要重新授权**）。

## 已完成 ✅

### M1 语音链路（完整收官，用户实测验收通过）
按住遥控器语音键说话 → 豆包输入法出字，全自动。
链路：ATVV(BLE `AB5E000x`) → IMA ADPCM 16kHz 解码 → AVAudioEngine → BlackHole 2ch 虚拟声卡 → 豆包。
关键实现细节（全是实机踩坑换来的，别回退）：
- 豆包触发 = 合成**右 Option**（用户设置），事件类型必须 `.flagsChanged`（keyDown 型豆包看不见），带 IOKit 设备位 0x40。
- **hold 模式**（按下 keyDown/松开 keyUp）最可靠；tap/double 模式会残留语音条。
- 抖动防护三件套：收到**第一个音频帧**才触发豆包（幽灵会话零帧不触发）、松开去抖 250ms、最短按住 1s。
- 松开后**不要**发任何 dismiss 补键（会打断下一段话）。
- 麦克风延迟 1.2s 还原、输入法延迟 4s 还原。
- MIC_CLOSE 后遥控器会回 0x00，需 streaming 门控防乒乓。

### M2 按键映射（大部分可用，1 个遗留 bug）
架构（实机验证）：**macOS 禁止用户态 seize 蓝牙键盘**（0xE00002C1），正路是：
1. `hidutil` 设备级重映射：home/menu/tv/power/ok → F14-F18（系统零默认行为的中转键）
2. `CGEventTap`（active）捕获并吞掉中转键 keycode → 反查 RemoteKey → MappingEngine
3. 方向键/音量键 v1 保持系统原生（默认行为正好）
4. voice 键不中转（语音走 ATVV，与 HID 无关）
5. 退出时恢复 hidutil 空映射

已验证工作：菜单→调度中心、主页→Spotlight（macOS 26 无启动台，已做兜底）、OK→回车、TV→系统设置、音量原生、语音并行不干扰。
MappingEngine 支持 tap/hold/double/层/手势状态机（selfCheck 全过），配置 JSON 在 `~/Library/Application Support/MiRemote/config.json`（首次运行自动生成默认）。

## 遗留问题 ⚠️

**返回键（0xF1）完全收不到**——当前唯一硬 bug。
- 0xF1 超出标准键盘 usage 范围：hidutil 不认、macOS 事件系统忽略（原生无任何行为）。
- 早期 `tools/hidprobe.swift`（独立进程、IOHIDManager 监听模式）**能**读到 0xF1；但集成进主程序的 HIDEngine（同样监听模式）读不到任何键（诊断日志 IOHID 事件数=0）。
- 未验证的怀疑点：①主程序里 CGEventTap(active) 与 IOHIDManager 同进程共存是否互斥；②HIDEngine 的 runloop 调度（主 runloop 被占？）；③hidutil 映射装上后 IOHID 层看到的是映射后 usage（NULL 测试已证实），但 back 未映射应该仍是 0xF1。
- **下一步建议**：先单独跑 `/tmp/hidprobe`（tools/hidprobe.swift）+ 主程序同时运行，确认是共存问题还是 HIDEngine 代码问题；HIDEngine 的 InputValue 回调注册时序值得对照 hidprobe 逐行比对。

## 未开始（按 DESIGN.md 里程碑）

- M3 层/手势的实际按键接入（引擎已支持，缺方向键中转）
- M4 高级动作：窗口切换、Ghostty 标签跳转、focus_input、鼠标模式、宏
- M5 SwiftUI 界面（按 mockups/v3-macos.html + 渐进式披露原则：简单功能在外、350ms 等参数收进"高级设置"折叠、三步图文教程）
- M6 onboarding 三步向导 + .app 打包（脚本组装 bundle + 自签，见 DESIGN §8）

## 文件地图

```
Sources/MiRemote/
├── App/main.swift          # CLI 入口 + 全部接线（语音 VoiceBridgeApp + 按键 KeyMapperApp）
├── App/Contracts.swift     # 模块间契约（RemoteKey usage 实测表在这里）
├── App/SelfTest.swift      # --self-test 全部测试
├── Bluetooth/ATVVBridge.swift    # ATVV 状态机（经 Fable 审查 + 修复 C1-C7）
├── Bluetooth/ADPCMDecoder.swift  # IMA ADPCM + FrameAccumulator + 后处理
├── Audio/AudioBridge.swift       # PCM→BlackHole；WAVSink 调试；TeeSink
├── Audio/DefaultInput.swift      # 默认麦克风切换/还原
├── HID/KeyRemapper.swift   # hidutil 中转表 + TapEngine(CGEventTap)
├── HID/HIDEngine.swift     # IOHID 监听（back 键通道，当前收不到——遗留bug）
├── Mapping/MappingEngine.swift   # tap/hold/double/层/手势状态机
├── Actions/ActionRunner.swift    # CGEvent合成(左右修饰键)/系统动作/openApp/shell
└── Actions/VoiceTrigger.swift    # 豆包触发（右Option hold + 防抖 + IME切换）
tools/    # hidprobe(usage探针) rawdump eventmon taptest 四个诊断工具
```

## 运行时注意
- 老 app「小米遥控器助手」勿与本程序同时运行（抢 ATVV/HID）。
- 交接时系统已恢复干净：进程已停、hidutil 映射已清空。
