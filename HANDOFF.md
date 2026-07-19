# 交接文档（2026-07-19）

## 项目
小米蓝牙遥控器 2 Pro（VID 0x2717 / PID 0x32B8，13 键，无静音键）→ macOS 全能控制台。
Swift 6 / SwiftPM 布局 / 零第三方依赖。设计文档 `DESIGN.md`，测试清单 `TESTPLAN.md`，UI 定稿 `mockups/v3-macos.html`（macOS 系统设置风，用户已确认）。

## 构建与运行

```bash
./build.sh                      # swiftc 直编（不要用 swift build，见下）
.build/miremote --self-test     # 内置自检，全绿
.build/miremote --verbose --doubao --keys   # 完整运行（语音+按键）
```

- **不要用 `swift build` 跑测试**：CLT 不带 XCTest/Swift Testing，测试编进二进制用 `--self-test` 跑。
- build.sh 里 `-sectcreate` 嵌入 Info.plist（CLI 用 CoreBluetooth 必需）+ 自签。
- 本机 CLT 曾坏过一次（SDK/编译器错配），已重装 CLT 26.6 修复。
- 权限：需「输入监控」+「辅助功能」（`.build/miremote` 手动加入辅助功能列表；**每次重编译后临时签名变化，可能要重新授权**）。

## 2026-07-19 最终收口状态

- 核心终审加固已落盘：语音触发会话配置锁存与对称释放、服务停止强制收尾、EventListener 非阻塞连接/超时/并发上限、映射健康三态、单实例 GUI/CLI 分流，以及相关自检。
- UI 第 4 轮修正与浅/深色截图已落盘；未纳入当前发布的建议保存在 `docs/UI-REVIEW-BACKLOG.md`。
- 实机权限问题已修：蓝牙授权请求对象被强持有；蓝牙被拒绝时直达系统隐私设置；每次启动都会重新检查蓝牙、输入监控、辅助功能，缺任一项即重新显示授权向导。
- 第 4 次双评审已闭环：退出会同步排空 ATVV/语音触发并立即补 keyUp、恢复输入法/麦克风；精简重授权与组合失权路由已分开；正式 DMG 固定证书身份、ZIP 当前构建 CDHash/DR/bundle id 均有硬校验。
- 实机操作收口修正：“所有 App”窗口选择通过 NSWorkspace 协作式激活交接；Home 单按直达 Mission Control 显示桌面，不再依赖 Fn+F11；聚焦输入改为可见候选评分，编辑区优先于侧栏搜索。
- Home 双击已有独立语义：单击显示桌面、双击调度中心，不再连续两次显示桌面造成一来一回；从 MiRemote 进入调度中心后，20s 内下一次菜单短按优先发 Esc 退出。
- 应用形态改为 Dock + 菜单栏双入口：运行时 Dock 图标常驻，关闭设置窗口不退出服务，再点 Dock 图标会重开设置窗口。
- 系统功能菜单删除了与实体音量键重复且不对称的“音量＋”，保留遥控器没有独立键的“静音”；常规功能区重排为 3×3。
- 防卡模式超时：窗口选择/系统菜单/教程 10s 无操作自动关闭，App 轮盘保持 3s，锁定控制层与鼠标模式 20s 无操作自动退出。
- 自动门槛：`./build.sh && .build/miremote --self-test`。蓝牙/TCC 系统弹窗与真实撤权恢复仍需在打包 `.app` 上做一次人工实机验收。

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

**Secure Input 限制（v1 接受）**：密码输入（Secure Event Input）期间 CGEventTap 被系统旁路而 hidutil 映射仍生效，遥控器方向键会以中转键（F13/F19/F20/小键盘 Clear）泄漏进前台应用（仅遥控器受影响，真键盘不经过重映射不受影响）；未来可轮询 `IsSecureEventInputEnabled()` 在 Secure Input 期间临时卸载方向键映射。

**返回键（0xF1）完全收不到**——已修复，**实机验证通过**（2026-07-19，全键位+语音并行均正常）。
- 根因（代码对照 hidprobe 得出）：HIDEngine 先试 `IOHIDManagerOpen(seize)`（蓝牙键盘必失败 0xE00002C1）→ `IOHIDManagerClose` → 再以 None 重开。同一 IOHIDManager 失败 open 后 close 再 open，重开返回 success 但已枚举设备不会真正重新打开——InputValue 回调永远零事件。hidprobe 从不走这个流程，所以能读到 0xF1。
- 修复：HIDEngine 删除整条 seize 路径，直接监听模式打开（与 hidprobe 一致）。自检全绿。
- **验证方法**：`.build/miremote --verbose --keys`，按返回键应看到 `IOHID读到 back` 日志且触发退格。若仍收不到，再查 CGEventTap 同进程共存（对照实验：注释 tap.start() 单跑 HIDEngine）。

## 当前进度（按 DESIGN.md 里程碑）

- M3 层/手势实际按键接入：已完成。
- M4 高级动作（窗口切换、标签跳转、focus_input、鼠标模式、宏）：已完成。
- M5 SwiftUI：四页主界面、菜单栏 6 态、遥控器示意图、录制式绑定、预设与 JSON 导入导出、体检修复页均已完成。
- M6：三步 onboarding 与打包/签名/lint 脚本已完成；本机尚需执行 `scripts/setup-signing.sh` 并完成钥匙串信任后，才能产出正式签名 `.app`。

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
