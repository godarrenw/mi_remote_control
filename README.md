<div align="center">

# MiRemote

**小米蓝牙遥控器 2 Pro → macOS 全能控制台**
躺着就能指挥 AI 写代码：按住语音键对遥控器说话直接出字，13 个键映射成 Mac 的任何操作。

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)
[![zero dependency](https://img.shields.io/badge/dependencies-0-brightgreen)](Package.swift)

</div>

> **MiRemote** turns a Xiaomi Bluetooth Remote 2 Pro into a full macOS controller. Hold the
> voice key and talk — your speech is typed into the focused field via a private ATVV audio
> channel and an IME. The 13 physical keys map to keystrokes, window switching, tab jumping,
> a mouse mode, per-app profiles, and an "approve/reject" layer for AI coding agents. Native
> Swift 6, zero third-party dependencies.

---

## 为什么做这个

一个躺在沙发上就能指挥终端里 AI Agent 的遥控器：说话写代码，方向键翻结果，一个键批准/拒绝
Agent 的改动。小米这颗遥控器便宜、手感好、带麦克风，蓝牙链路上按键和语音是两条独立通道，
刚好能被 Mac 全接管。

## 核心特性

- **语音输入** — 按住语音键对遥控器说话，文字落进当前输入框。走遥控器内置麦克风 →
  ATVV 私有 GATT → IMA ADPCM 解码 → BlackHole 虚拟声卡 → 豆包输入法，全自动。
- **13 键 × 多触发** — 每个键支持 tap / hold / double / 层 / 手势（OK+方向），
  一颗遥控器压出数十个动作位。
- **App 控制模式** — TV 键进入 per-app 高级操作层，弹出 HUD 提示；方向/OK/返回/音量±
  在模式内执行当前 App 的专属动作。
- **AI 批准层** — 终端 App 里 OK=批准、返回=拒绝、音量±=切 Agent、菜单=Shift+Tab，
  给 AI Coding Agent 的确认流量身定制。
- **窗口选择器** — 菜单键弹出浮层，左右选窗、上下扩范围（当前 App → 所有 App），
  OK 确认、返回关闭。
- **健康自愈** — `--doctor` 一键体检并修复权限/BlackHole/残留映射等常见问题。
- **预设库** — 内置 Ghostty / 微信 / 浏览器 / 视频播放器等 profile，overlay 继承模型，
  一键导入、JSON 导出分享。
- **零依赖** — 全部原生框架（CoreBluetooth / IOKit / CoreGraphics / AVFoundation /
  SwiftUI），无任何第三方包。

## 架构一览

```
┌─────────── 遥控器 (BLE) ───────────┐
│  通道1: 按键 = 标准 HID (系统接管)   │
│  通道2: 语音 = ATVV 私有 GATT 服务   │
└───────────────┬───────────────────┘
                │
┌───────────────▼─── MiRemote ──────────────────────────┐
│ HIDEngine        CoreBluetooth/ATVV                    │
│ (hidutil 中转     (握手→ADPCM解码→PCM)                  │
│  + CGEventTap)         │                               │
│      │                 │                               │
│ MappingEngine     AudioBridge                          │
│ (层/长按/双击/     (PCM→BlackHole 虚拟声卡)             │
│  手势/per-app)         │                               │
│      │                 ▼                               │
│ ActionSystem      豆包输入法选 BlackHole 当麦克风 → 文字 │
│ (按键/窗口/标签/                                        │
│  聚焦/鼠标/宏/脚本)                                     │
└────────────────────────────────────────────────────────┘
```

按键与语音是 BLE 链路上两条互不干扰的通道：按键走标准 HID，用 `hidutil` 设备级重映射到
无副作用的中转键、再由 `CGEventTap` 捕获解析；语音走 ATVV 私有 GATT，CoreBluetooth 直连，
系统不占用。详见 [DESIGN.md](DESIGN.md)。

## 快速开始

```bash
# 1. 构建（只需 Command Line Tools，不用完整 Xcode）
./build.sh
.build/miremote --self-test      # 内置自检应全绿

# 2. 打包（首次需先建固定签名证书，见下）
./scripts/setup-signing.sh       # 一次性：创建 "MiRemote Dev" 自签证书
./scripts/package.sh             # 组装 + 签名 .app → dist/
./scripts/make-dmg.sh            # 打成 DMG → dist/MiRemote-<version>.dmg

# 3. 首次授权：向导会逐项引导蓝牙 / 输入监控 / 辅助功能
```

> 用 `./build.sh`（swiftc 直编）而非 `swift build`：CLT 不带 XCTest，测试编进二进制用
> `--self-test` 跑。想只看 GUI 用 `.build/miremote --ui-preview`。

## 键位速查

| 键 | 单击 | 长按 |
|---|---|---|
| 方向 ↑↓←→ | 光标移动 | 连续移动 |
| OK | 回车 | 进入层 1（+方向=手势：调度中心/窗口循环/前后标签） |
| 返回 | 删除 / 关闭浮层 | — |
| 主页 | 显示桌面 | 当前 App 映射教程浮层 |
| 菜单 | 窗口选择器浮层 | 完整系统功能菜单浮层 |
| TV | 进/出 App 控制模式 | 当前 App 主操作 |
| 音量 ± | 音量（控制模式内=上一个/下一个） | 连续调 |
| 语音 | 按住说话 → 出字 | — |
| 电源 | 显示器睡眠 | 鼠标模式开关（方向键移指针、OK=点击） |

**迷路了？长按菜单键 1.5 秒 = 逃生键**：无论当前在哪个层、开着什么浮层，都会强制清空
所有层、退出 App 控制模式并关闭全部浮层，回到基础状态（硬编码兜底，不受配置影响）。

层激活 / 鼠标模式 / 语音中三种隐藏态都会在菜单栏图标变色 + 屏幕角标上同步显示。
双击判定窗口默认 250ms，只对配置了双击动作的键生效（如 Zoom 预设的 TV 键），
其余键短按零延迟。完整触发模型与默认配置见 [DESIGN.md §3](DESIGN.md)。

## 截图

<!--
  截图待 UI 定稿后补：
  - docs/shot-mapping.png   按键映射主页（遥控器示意图 + 编辑面板）
  - docs/shot-voice.png     语音页（电平表 + BlackHole 状态）
  - docs/shot-hud.png       App 控制模式 HUD / 窗口选择器浮层
-->
_（界面截图待补）_

## FAQ

**升级后按键没反应？** 正常现象，不是坏了：MiRemote 没做 Apple 公证，**每次升级新版本，
macOS 都会要求重新授权一次**（系统设置 → 隐私与安全性 → 输入监控 / 辅助功能，把 MiRemote
删掉重新勾选）。整个过程约 30 秒，**你的按键设置不会丢失**（配置文件不受升级影响）。
自己从源码开发的例外：本机用固定 `MiRemote Dev` 证书 + 固定 bundle id 重编译不掉权限，
用临时（ad-hoc）签名则每次都掉，所以 `package.sh` 在缺证书时会硬失败而非回退。

**为什么语音要 BlackHole？** 遥控器麦克风的音频先解码成 PCM，需要一个虚拟声卡把它喂给
输入法当麦克风。安装 [BlackHole 2ch](https://existential.audio/blackhole/)（免费）后在
豆包输入法里把麦克风选成 BlackHole 2ch 即可。它不设为系统默认设备，不影响正常通话。

**退出后遥控器/键盘按键异常？** MiRemote 退出时会自动清空 `hidutil` 中转映射；若异常退出
没清干净，终端执行 `hidutil property --set '{"UserKeyMapping":[]}'` 即可恢复。

**Secure Input 期间方向键会漏字符？** 已知限制：密码输入（Secure Event Input）期间系统旁路
`CGEventTap` 但 `hidutil` 映射仍生效，遥控器方向键可能以中转键泄漏进前台（真键盘不受影响）。
v1 接受此限制。

## 安装（分发包）

拿到 `.dmg` 或 `.zip` 的朋友：

1. 打开 DMG，把 `MiRemote.app` 拖进「应用程序」；或解压 zip 后拖入。
2. **首次打开**：右键（或按住 Control 点击）MiRemote.app → 打开 → 再点「打开」。
   直接双击会提示"无法验证开发者"（没做 Apple 公证），属正常，右键打开即可；
   若仍被拦，去「系统设置 → 隐私与安全性」页面底部点「仍要打开」。
3. 按向导授予蓝牙 / 输入监控 / 辅助功能三项权限，改完权限没生效就退出重开一次
   （注意：点窗口红叉只是关窗不是退出，请从菜单栏图标选「退出」再重开）。
4. **每次升级新版本，macOS 会要求重新授权一次**（约 30 秒，设置不会丢失）——
   这是未公证 App 的正常安全机制，见 FAQ「升级后按键没反应？」。
5. 遥控器连不上：长按 **主页+返回 3 秒**至指示灯闪烁进入配对，在系统蓝牙里点连接；
   别同时运行官方「小米遥控器助手」（会抢设备）。

语音打字额外需要装 BlackHole 2ch 与豆包输入法，见上方 FAQ。

## 致谢

- [open-voice-bridge](https://github.com/) — ATVV 协议与 IMA ADPCM 解码的开源参考实现。
- [BlackHole](https://existential.audio/blackhole/) — 免费开源虚拟声卡（GPLv3）。

## License

[MIT](LICENSE) © MiRemote contributors
