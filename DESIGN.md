

# 小米蓝牙遥控器 2 Pro → macOS ·控制台 技术设计文档

> 版本 v1.0 · 2026-07-19
> 目标设备：小米蓝牙遥控器 2 Pro（蓝牙 5.4，内置电池，Type-C，VID 0x2717 / PID 0x32B8，蓝牙名 "MI RC" 系）
> 目标平台：macOS 14+（本机 26.5 已验证工具链）
> 语言：Swift 6（SwiftPM，Command Line Tools 即可构建，无需完整 Xcode）

---

## 0. 一页总览

把遥控器变成 Mac 的万能控制器：**13 个物理键 × (短按/长按我要测试一下说话/双击/层/手势) → 数十个可自定义动作**，外加**遥控器麦克风语音输入**（可切换为

 Mac 内置麦克风），语音识别交给豆包输入



```
┌─────────── 遥控器 (BLE) ───────────┐
│  通道1: 按键 = 标准 HID (系统接管)   │
│  通道2: 语音 = ATVV 私有 GATT 服务   │
└───────────────┬───────────────────┘
                │
┌───────────────▼─── 本 App ────────────────────────────┐
│ HIDEngine        CoreBluetooth/ATVV                    │
│ (IOHID 独占按键)  (握手→ADPCM解码→PCM)                  │
│      │                  │                              │
│ MappingEngine     AudioBridge                          │
│ (层/长按/双击/     (PCM→BlackHole 虚拟声卡)             │
│  手势/per-app)          │                              │
│      │                  ▼                              │
│ ActionSystem      豆包输入法选 BlackHole 当麦克风 → 文字 │
│ (按键/窗口/标签/                                        │
│  聚焦/鼠标/宏/脚本)                                     │
└────────────────────────────────────────────────────────┘
```

---

## 1. 蓝牙原理（为什么能这么做）

### 1.1 配对：Just Works，无任何密钥操作

遥控器是 BLE 设备，配对走标准 SMP 流程。它没有屏幕和数字键（IO Capability = NoInputNoOutput），按蓝牙规范自动退化为 **Just Works 无 PIN 配对**。用户操作只有两步：

1. 长按组合键约 3 秒进入配对广播（常见为「主页+返回」或「设置+主页」，LED 闪烁为准；具体组合以实测为准，写进引导页）。
2. Mac 系统设置 → 蓝牙 → 点连接。完成后双方保存长期密钥（bonding），此后自动回连。

### 1.2 两条互相独立的通道

**通道 1（按键）= HID over GATT (HOGP)**：遥控器暴露标准 HID 服务（0x1812），macOS 蓝牙栈配对后直接当键盘接管，按键以标准 HID usage 上报。App 不碰 GATT，而是在系统 HID 层用 `IOHIDManager` 按 VID/PID 独占（seize）这个设备，拿到原始 report 自己解析。

**通道 2（语音）= ATVV 私有 GATT 服务**：Google Android TV Voice 协议，服务 UUID `AB5E0001-5A21-4F05-BC7D-AF01F617B664`。macOS 系统不认识它、不会占用，App 用 CoreBluetooth 直连，与系统的 HID 连接共存于同一条 BLE 链路，互不干扰。

> UUID 分歧说明：open-voice-bridge（本机"小米遥控器助手"的开源版，已在本型号实测跑通）用 `AB5E000x`；上游 remote-bridge-hub（Windows 版）记录的是 `6e40000x`（Nordic UART 布局）。**以 `AB5E000x` 为准**（本机 app 二进制字符串与开源代码双重确认），实机联调时用服务发现日志再验一次。

### 1.3 ATVV 语音协议时序（实测版）

特征：`AB5E0002` TX（主机写命令）、`AB5E0003` Audio（notify，音频帧）、`AB5E0004` Control（notify，控制）。

```
App                                遥控器
 │── 订阅 0003 / 0004 notify ────────▶│
 │── TX 写 GET_CAPS (0A 01 00 00 03 03)▶│
 │◀─ CTL 0x0B 能力帧(版本/codec/帧长) ──│   codec&0x02→16kHz；帧长默认120B
 │        （用户按下语音键）             │
 │◀─ CTL 0x08 请求开麦 ────────────────│
 │── TX 写 MIC_OPEN (v≥1.0: 0C 00) ───▶│
 │◀─ CTL 0x04 流开始(codec/sessionID) ─│
 │◀═ Audio 0003 连续音频帧 ═══════════│   IMA ADPCM
 │◀─ CTL 0x0A 同步帧(predictor/step) ──│   → 重置解码器状态
 │        （用户松开语音键）             │
 │◀─ CTL 0x00 流结束 ──────────────────│
 │── TX 写 MIC_CLOSE (0D <sessionID>) ─▶│
```

音频：**IMA/DVI ADPCM，16 kHz 单声道 16-bit**，4:1 压缩，每字节高/低 nibble 各解一个样本。解码器为标准 89 级 stepTable + indexTable，纯函数几十行，直接移植 open-voice-bridge 的 `ATVVProtocol.swift`。工程要点（均来自已验证实现）：

- 仅接受 16 kHz，否则断线重连；
- 每次连接分配递增 generation，旧代的回调/音频帧一律丢弃（防跨代串音）；
- `0x0A` 同步帧到达时用其中 predictor/stepIndex 重置解码器；
- 解码后做 [1,2,1]/4 三点平滑 + 可配增益。

### 1.4 按键 HID usage 表（三方交叉验证一致）

| usage | 实体键 | 位置 |
|---|---|---|
| 0x66 | 电源 ⏻ | 顶部左 |
| （F5, 键盘页 0x3E） | 语音 🎤 | 顶部右 |
| 0x52 / 0x51 / 0x50 / 0x4F | 方向 ↑↓←→ | 方向环 |
| 0x28 | 确认 OK | 环中心 |
| 0xF1 | 返回 < | 下区左列第 1 |
| 0x4A | 主页 ⌂ | 下区左列第 2 |
| 0x65 | 菜单 ≡ | 下区左列第 3 |
| 0x80 / 0x81 | 音量 + / − | 下区右列纵向长胶囊（跨左列前两行） |
| 0x35 | TV 自定义键 | 下区右列胶囊下方 |

（实物确认无独立静音键，共 13 个按键；Windows 版参考代码里的 0x7F mute 码不适用本型号。）

report 格式：reportID=1，每 2 字节一个小端 16-bit usage（Windows 侧抓包为 9 字节=头 3 字节 + 3 个 usage 槽，支持多键同按）。语音键上报为键盘页 F5——这就是它能被 hidutil/IOHID 重映射的原因。

---

## 2. 总体架构与模块划分

单一 SwiftPM 可执行目标，六个核心模块 + UI。全部原生框架，**零第三方依赖**（BlackHole 是外部系统组件，不是代码依赖）。

```
Sources/MiRemote/
├── Bluetooth/
│   ├── ATVVBridge.swift        # CoreBluetooth 连接 + ATVV 状态机
│   └── ADPCMDecoder.swift      # IMA ADPCM → PCM（纯函数）
├── Audio/
│   └── AudioBridge.swift       # AVAudioEngine：PCM → 指定输出设备(BlackHole)
├── HID/
│   ├── HIDEngine.swift         # IOHIDManager seize + report 解析 → ButtonEvent
│   └── VoiceKeyRemap.swift     # F5 → 无副作用 usage 的 UserKeyMapping
├── Mapping/
│   ├── MappingEngine.swift     # 层/短按/长按/双击/手势 状态机 → ActionRef
│   └── ProfileManager.swift    # 全局+per-app profile，前台 app 监听
├── Actions/
│   ├── KeyStroke.swift         # CGEvent 合成（含左右修饰键设备位）
│   ├── WindowSwitcher.swift    # CGWindowList + activate + AXRaise
│   ├── FocusInput.swift        # AX 树找输入框→AXFocused→坐标点击兜底
│   ├── MouseMode.swift         # 方向键控光标（加速度）
│   ├── VoiceTrigger.swift      # 切豆包输入法 + 双击左Option
│   └── Macro.swift             # 多步序列执行器（含 shell/AppleScript）
├── App/
│   ├── AppModel.swift          # 中枢：串联各模块 + 状态发布
│   ├── Onboarding.swift        # 权限/BlackHole/配对 三步向导
│   └── main.swift
└── UI/  (SwiftUI)
    ├── MainWindow.swift        # 设置主窗口（可视化遥控器）
    ├── RemoteDiagram.swift     # 纯代码矢量遥控器示意图
    ├── BindingEditor.swift     # 单键映射编辑面板
    ├── VoicePage.swift         # 语音模式/电平表/BlackHole 状态
    └── StatusItem.swift        # 可选菜单栏图标
```

数据流：`HIDEngine → ButtonEvent → MappingEngine(结合当前 profile/层状态) → ActionRef → ActionSystem 执行`；语音独立一条：`ATVVBridge → ADPCMDecoder → AudioBridge → BlackHole`。

---

## 3. 按键映射引擎（核心设计）

### 3.1 触发模型：每键五个"动作位"

借鉴 Karabiner(tap/hold) + 雷蛇 Hypershift(层) + 罗技手势键，每个物理键支持：

| 触发 | 说明 | 默认阈值 |
|---|---|---|
| `tap` | 短按松开 | — |
| `hold` | 按住超阈值 | 350ms，可调 |
| `double` | 双击 | 窗口 250ms，可关（关了 tap 零延迟） |
| `layer:x` | 某层激活时的映射 | — |
| `gesture` | 仅 OK 键：按住 OK + 方向键 = 4 个动作 | — |

层机制：任意键的 `hold` 可绑 `momentary_layer(1)`（按住进层，松开回落）或 `toggle_layer(1)`（点击锁定）。12 键 × 2 层 × (tap/hold/double) 理论上限 70+ 动作位，实际推荐默认配置只用 ~25 个，其余留给用户。

**状态反馈铁律**（少按键设备成败关键）：层激活/鼠标模式/语音中三种隐藏态，都在菜单栏图标变色 + 可选提示音 + 屏幕角落浮动小角标（NSPanel，非侵入）上同步显示。

### 3.1b 按键心智模型 v2（2026-07-19 与用户定稿，默认配置以此为准）

四层模型：**内容操作**（方向/OK/返回/语音=光标/确认/删除/输入）｜**同级切换**（音量±）｜**系统导航**（Home/菜单）｜**App 专用**（TV）。原则：不靠双击做高频操作；一切模式必须有可视反馈；键帽印刷优先（新手零学习）；**默认配置零同按组合**（单手拇指操作，按住 A 再按 B 的手势不进默认——交互全部序列化：单击/长按/双击 + 浮层停留式选择；引擎保留同按手势能力供高级用户自配）。

| 键 | 单击 | 长按 | 说明 |
|---|---|---|---|
| 音量± | 音量（跟键帽一致） | 连续调 | **TV/App 控制模式内**=上一个/下一个（Tab/会话/页），HUD 提示 |
| Home | 显示桌面（零延迟，不配双击） | 当前 App 映射教程浮层 | Mission Control 移入功能菜单 |
| 菜单 | 窗口选择器浮层（左右选窗、上下/再按菜单键扩范围：当前 App→所有 App、OK 确认、返回/空白关闭） | 完整系统功能菜单浮层（Mission Control/App Exposé/左右桌面/聚焦输入框/媒体/锁屏睡眠） | v1 就做完整选择器 |
| TV | 进/出 **App 控制模式**（弹小型操作提示 HUD；模式内方向/OK/返回/±执行当前 App 高级操作） | **App 轮盘（停留式）**：长按弹出后松手，轮盘停留；方向环选五大 App（Ghostty/ChatGPT/飞书/微信/浏览器），OK 或再按 TV 确认切换，返回取消，3s 无操作自动关 | 双击 v1 不定义。「当前 App 主操作」=控制模式内长按 OK。AI 批准=终端 App 的控制模式绑定（OK=批准/返回=拒绝/±=切 Agent/菜单=Shift+Tab）。跨 App 铁律：±=切换、OK=发送/批准、返回=取消/停止（详见 scratchpad/vibe-scenarios.md 五 App 绑定表）。OK+方向同按手势与 OK 长按瞬时层已从默认配置移除（零同按原则），引擎能力保留 |
| 教程/浮层通用 | — | — | 再按同键或返回/Esc/点空白关闭；不影响录制模式对 Esc 的捕获 |

实现映射：App 控制模式=层机制+per-app 层绑定+HUD；浮层需要「UI 模态路由」——浮层打开时 MappingEngine 把遥控键喂给浮层而非动作（新增 uiCapture 路由态）。新增 system 动作：show_desktop。

**手柄/主机范式采纳（2026-07-19，源 scratchpad/gamepad-ux.md）**：①**按键提示条 HintBar**——模式/浮层激活时屏底半透明小条实时显示每键当前含义（比教程浮层更好的可发现性，PS5 glyph bar 范式）；②**长按语义铁律**——任何键的长按=「当前对象的更多/展开」，用户可预测；③**回切上一个 App**：轮盘打开时默认选中「上一个 App」（TV 长按→OK 两步回切）；TV 双击保持不定义——配双击会让高频单击吃 250ms 判定延迟，违反"不靠双击做高频操作"；要单键回切自配 system("app_mru_back")；④轮盘中心=取消待定态（Steam radial 规范，扇区≤8）；⑤hold-to-confirm 填充圈（熄屏/锁屏/退出等危险操作）；⑥列表导航按住加速（浮层内方向键长按加速滚动）；⑦前台 App 切换致 profile 变化时闪现角标「现在是微信布局」+可选音效（Steam Deck 层切换无提示是公认短板）。焦点视觉=tvOS 范式：放大 1.06-1.08+抬升阴影+0.22s spring，非选中降透明度。

### 3.2 动作类型清单（ActionRef）

```
key_stroke      单键/组合键输出。录制式配置，支持左右修饰键区分与多修饰组合
system          音量±/静音/亮度/播放暂停/睡眠/锁屏/启动台/调度中心/截图
open_app        打开或激活指定 app（bundle id）
window_cycle    同应用窗口循环 / 全局窗口切换器
tab_jump        向前台 app 发 cmd+数字 / cmd+shift+[] （Ghostty/浏览器通吃）
focus_input     自动聚焦前台 app 的文本输入框（详见 §5）
mouse_mode      进入/退出鼠标模式（方向键=光标，OK=左键，菜单=右键）
voice           语音输入（详见 §6，模式可选）
macro           多步序列：按键/文本/延时/打开app/URL/上述任意动作
shell           运行 shell 命令 / AppleScript（无限扩展兜底）
profile_switch  手动切 profile / 切层
none            透传或屏蔽
```

### 3.3 Profile：全局默认 + per-app 覆盖

- 一套 `global` profile 打底；每个 per-app profile 只声明要覆盖的键，其余继承 global（overlay 模型，配置量最小）。
- `NSWorkspace.didActivateApplicationNotification` 监听前台 app bundle id，自动热切换。
- 内置预设库：Ghostty（方向键=切标签 cmd+数字、OK=回车、返回=Ctrl+C）、微信（上下=切会话、OK=发送）、浏览器、视频播放器。用户可导入导出 JSON 分享。

### 3.4 配置文件格式（示例）

```jsonc
{
  "version": 1,
  "settings": { "holdMs": 350, "doubleMs": 250, "statusItem": true },
  "profiles": {
    "global": {
      "ok":    { "tap": {"type":"key_stroke","key":"return"},
                 "hold": {"type":"momentary_layer","layer":1},
                 "gesture": { "up":{"type":"system","action":"mission_control"},
                              "down":{"type":"window_cycle"},
                              "left":{"type":"tab_jump","dir":-1},
                              "right":{"type":"tab_jump","dir":1} } },
      "voice": { "tap": {"type":"voice"} },
      "tv":    { "tap": {"type":"focus_input"},
                 "double":{"type":"open_app","bundle":"com.mitchellh.ghostty"} },
      "up":    { "tap": {"type":"key_stroke","key":"up_arrow"},
                 "layer:1": {"type":"key_stroke","key":"k","mods":["right_option"]} }
    },
    "com.tencent.xinWeChat": {
      "_inherits": "global",
      "ok": { "tap": {"type":"macro","steps":[
                {"key_stroke":"return"} ]} }
    }
  }
}
```

存 `~/Library/Application Support/MiRemote/config.json`，UI 全量读写它；高级用户可直接改文件（FSEvents 监听热加载）。

### 3.5 HID 层实现要点

- `IOHIDManager` 按 VID 0x2717 / PID 0x32B8 匹配，优先 `kIOHIDOptionsTypeSeizeDevice` 独占（系统收不到原始按键，杜绝双触发）；独占失败降级为监听模式 + CGEventTap 吞掉遥控器产生的系统事件（用 eventSourceUserData 魔数标记自己合成的事件避免误吞——open-voice-bridge 的成熟做法）。
- 语音键（F5）用 `IOHIDServiceClient` 的 `UserKeyMapping` 属性做硬件层重映射到无副作用 usage，只匹配本遥控器 VID/PID，退出时恢复（防止污染真键盘 F5）。
- 需要「输入监控」+「辅助功能」权限，运行时周期校验，被撤权即释放设备并在 UI 提示。

---

## 4. 高级动作实现方案

### 4.1 合成按键（含左右修饰键）

CGEvent 公开 flags 不分左右；要精确左右必须 OR 进 IOKit 设备位（IOLLEvent.h）：

| 修饰键 | keycode | 设备位 |
|---|---|---|
| 左/右 Cmd | 55 / 54 | 0x08 / 0x10 |
| 左/右 Shift | 56 / 60 | 0x02 / 0x04 |
| 左/右 Option | 58 / 61 | 0x20 / 0x40 |
| 左/右 Ctrl | 59 / 62 | 0x01 / 0x2000 |

普通组合键：主键 keyDown/keyUp 各带 `CGEventFlags`（多修饰 OR 起来）。需要"裸修饰键双击"（如豆包的双击左 Option）时，单独 post 修饰键 down/up 并带上设备位。

### 4.2 窗口切换

`CGWindowListCopyWindowInfo` 枚举（owner PID/标题/bounds）→ `NSRunningApplication.activate()` 激活 app → `AXUIElementPerformAction(window, kAXRaiseAction)` 精确前置目标窗口（单用 activate 只能带出上次最前的窗口）。参考 AltTab 开源实现。两种玩法：
- `window_cycle`：同 app 多窗口循环（等效 cmd+`）或全局 MRU 循环；
- 进阶（v2 再做）：OK 长按弹出窗口选择浮层，方向键选中、OK 确认。

### 4.3 Ghostty / 浏览器标签页

Ghostty 无 IPC/AppleScript，但默认键绑完善：**合成 `cmd+数字` 直跳第 N 标签**（比 next/prev 相对切换稳），`cmd+shift+[/]` 相对切换。同一套 `tab_jump` 动作对浏览器/VS Code 通用（都认 cmd+数字）。按前台 app 可在 profile 里覆写具体快捷键。

### 4.4 自动聚焦输入框（focus_input）

按 app 类型三级策略，逐级兜底：

1. **终端 TUI（Claude Code / Codex CLI）**：聚焦终端窗口本身即等于聚焦输入行（TUI 无独立 AX 文本框），做完 §4.2 的窗口前置就结束——最简单的一类。
2. **AX 树查找**：在前台 app 的 AX 树里找 `AXTextArea`/`AXTextField`（网页类在 `AXWebArea` 下），设 `AXFocused = true`。Chromium/Electron（Grok、ChatGPT 桌面版）默认不暴露 AX 树，先对其 AXUIElement 写 `AXManualAccessibility = true`（Electron）与 `AXEnhancedUserInterface = true`（Chromium）各试一次再遍历。微信的输入框在 AX 树可见，且切到聊天窗口后焦点天然在输入框，通常直接打字即可。
3. **坐标点击兜底**：AX 拿到输入框 `AXPosition/AXSize` 算中心点，CGEvent 合成 leftMouseDown/Up 点一下。对自绘 UI 的顽固 app 这是最可靠落点。

### 4.5 鼠标模式

toggle 进入：方向键=光标移动（按住匀加速：初速 4px/tick → 1.5s 加到 40px/tick，60Hz 定时器 + `CGWarpMouseCursorPosition` 或 mouseMoved 事件），OK=左键点击，菜单=右键，返回=退出模式。音量键保留原功能。状态角标常显，防止"为什么按键失灵"的困惑。

---

## 5. 语音输入（双模式，可切换）

设置页三选一，也可绑到某个键上循环切换：

**模式 A：遥控器麦克风（主打）**
```
按下语音键 → ATVVBridge MIC_OPEN → ADPCM→PCM(16k)
  → AudioBridge 用 AVAudioEngine 写入 BlackHole 2ch 输出
  → 豆包输入法把麦克风选为 BlackHole → 识别出文字落入当前输入框
松开语音键 → MIC_CLOSE → 停止
```
配套：按下语音键时自动触发豆包进入语音状态（见模式 B 的触发手法），松开自动结束——用户感知就是"对着遥控器说话，文字出现"。BlackHole 不设为系统默认设备，不影响正常通话。

**模式 B：Mac 内置麦克风**
不碰音频，只做触发：记录当前输入法 → `TISSelectInputSource` 切到豆包（bundle `com.bytedance.inputmethod.doubaoime.pinyin`）→ 合成**双击左 Option**（带设备位 0x20，豆包默认语音触发键）→ 说话（Mac 麦克风收音）→ 再次按键结束 → 恢复原输入法。已有开源验证（Doubao-ime-hammerspoon）。

**模式 C：关闭**——语音键可当普通键映射别的功能。

备选：系统听写（程序化双击 Fn 不可靠，仅作为用户自行改绑普通快捷键后的可选触发目标）。

---

## 6. UI 设计

### 6.1 双形态窗口（响应"不喜欢常驻菜单栏"）

- **主形态**：正常 SwiftUI 设置窗口 + Dock 图标，所有配置在窗口内完成。
- **关窗后**：不退出，转后台继续工作；`NSApp.setActivationPolicy(.accessory)` 动态隐藏 Dock 图标。再次从启动台/Dock 点 app 图标唤回窗口（恢复 `.regular`）。
- **菜单栏图标：可选**。默认显示极小状态图标（连接/profile/层/语音状态一眼可见 + 快捷开关），设置里可彻底关闭——关闭后完全隐形。隐藏态反馈由浮动角标兜底。

### 6.2 页面结构

1. **按键映射页（主页）**：左侧纯代码矢量绘制的遥控器示意图（按实物布局：顶部电源+语音，方向环+OK，下方返回/菜单/主页/TV/音量±），选中键高亮；右侧该键的 tap/hold/double/层/手势 编辑面板。绑定快捷键用**录制式输入**（按下真实组合键直接记录，天然区分左右修饰键）。
2. **Profile 页**：全局+per-app 列表，添加时从运行中 app 选取；预设库一键导入；导入导出 JSON。
3. **语音页**：三模式切换、BlackHole 状态检测与一键安装修复、实时电平表（按语音键看到波形跳动，最好的排障工具）、增益调节。
4. **通用页**：阈值调节、开机自启（SMAppService）、菜单栏图标开关、提示音开关。
5. **引导流程**（首次启动自动进入，之后可从设置重进）见 §7。

---

## 7. 首次启动引导与环境自动配置

三步向导，每步自动检测状态、给出一键操作：

1. **权限**：蓝牙（Info.plist 声明，首次连接自动弹）→ 输入监控 → 辅助功能。逐项检测（`IOHIDCheckAccess` / `AXIsProcessTrusted`），未授权则一键跳转对应系统设置面板，授权后自动进下一步。
2. **BlackHole**（仅模式 A 需要，可跳过）：检测 `/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver`；未装则用内置的 BlackHole 安装包（GPLv3，随 app 分发合规）执行安装，随后 **`sudo killall coreaudiod` 重启音频服务即生效（声音中断约 1 秒），全程不重启电脑**（管理员密码通过系统授权弹窗获取）。
3. **配对**：CoreBluetooth 检测遥控器是否已连接；未配对则图示"长按 主页+返回 3 秒至指示灯闪烁"，扫描到即引导去系统蓝牙点连接，检测到 HID 设备出现即完成。

引导完成即进入可用状态；语音模式 A 额外提示一次"在豆包输入法设置里把麦克风选为 BlackHole 2ch"。

---

## 8. 构建、打包与分发

- **构建**：`swift build -c release`（CLT 自带 Swift 6.2.3，无需 12GB Xcode；本机磁盘余 76GB 充裕）。
- **打包**：脚本组装 `.app`（Contents/Info.plist + MacOS/二进制 + Resources/BlackHole安装包·默认配置·图标），`codesign -s - --force --deep` 自签。Info.plist 关键项：`NSBluetoothAlwaysUsageDescription`、`LSUIElement` 不设（用动态 activation policy）、`LSMinimumSystemVersion 14.0`。
- **分发（小范围朋友）**：zip 直发。无公证 app 首次打开需在「系统设置→隐私与安全性」点一次"仍要打开"，README 写清楚。后续想扩大范围再买开发者账号做公证，代码零改动。

---

## 9. 里程碑（建议实施顺序）



| 阶段 | 内容 | 验收标准 |
|---|---|---|
| M1 语音桥 CLI | ATVV 连接+握手+ADPCM 解码+输出 BlackHole | 豆包选 BlackHole 后，对遥控器说话能打出字 |
| M2 按键引擎 | IOHID 独占+report 解析+基础 key_stroke 映射（JSON 配置） | 方向键/OK/返回按 JSON 映射生效，无双触发 |
| M3 映射引擎 | 层/长按/双击/手势/per-app profile | 示例配置全触发路径可用 |
| M4 高级动作 | 窗口切换/tab_jump/focus_input/鼠标模式/宏/shell/豆包触发 | 各动作在 Ghostty/微信/Grok 实测通过 |
| M5 UI | 主窗口+遥控器示意图+录制式绑定+语音页 | 不改 JSON 完成全部配置 |
| M6 引导+打包 | 三步向导+.app 组装+自签 | 新用户机上从 zip 到可用 ≤5 分钟、零重启 |

每阶段结束都有可运行交付物；M1 结束你就能用遥控器语音打字了。

## 10. 风险与预案

| 风险 | 概率 | 预案 |
|---|---|---|
| 2 Pro 的 ATVV UUID/版本与 open-voice-bridge 有出入 | 低（本机 app 已在同型号跑通） | M1 先写服务发现日志工具，实测确认再固化 |
| IOHID seize 拿不到独占 | 中 | 已设计降级路径：监听+CGEventTap 抑制 |
| Electron app AX 树打不开/找不到输入框 | 中 | 三级兜底最后是坐标点击；per-app 可配"聚焦=纯点击坐标" |
| 双击左 Option 触发豆包失效（豆包改版） | 低 | 触发键在设置里可自定义，跟随豆包设置 |
| macOS 26 对 CGEvent/AX 收紧 | 低 | 本机即 26.5，所有能力在 M1-M4 逐项实测 |
| 个别键 usage 与预置表不符 | 低 | 映射表按实测 report 动态学习（UI 提供"按一下识别按键"） |
