import Foundation

// MARK: - 内置预设库（DESIGN §3.3「内置预设库」）
//
// 本文件只提供【静态数据 + 纯函数】，不做任何接线。所有类型均来自 Contracts.swift。
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ 接线说明（给主会话后续做，本代理不碰 main.swift / 引擎）                    │
// └─────────────────────────────────────────────────────────────────────────┘
//
// 1) 层绑定类预设（bundleID == nil，如 aiApprovalLayer / multiAgentBindings）
//    合并进 config.profiles["global"]，其绑定全部写在 KeyBinding.layers["2"] 上，
//    即「层 2 激活时的 tap 替代」。层 1 已被 M3 默认配置（音量微调）占用，故 AI 批准层用层 2。
//
// 2) 进入 / 退出层 2 的触发方式尚未接线 —— 交由主会话在默认配置里定。建议：
//      TV 键 double = layer_toggle(2)     （粘性开关，进/出 AI 批准模式）
//    或 某键 hold  = layer_momentary(2)   （按住即层 2，松开回基础层）
//    注意：TV 在 aiApprovalLayer 里 layers["2"] 已被占为「数字 1」，
//    但 TV 的 base double 槽仍空闲，两者不冲突，可同时写。
//
// 3) 「长按 OK = Esc 中断」无法用当前 KeyBinding 模型在层内表达：
//    KeyBinding.layers 只提供 tap 替代，没有 per-layer 的 hold/double 槽。
//    可选接线：把 OK 的【base】hold 设为 .keyStroke("escape")（对所有层生效），
//    或后续给 Contracts 增加 per-layer 的完整槽（hold/double）。本文件不擅自改 Contracts。
//
// 4) per-app 预设（bundleID != nil，媒体 / 会议）合并进 config.profiles[bundleID]，
//    走 overlay 继承 global（DESIGN §3.3）。UI 可直接把某个 Preset 应用到用户配置。
//
// 5) apply(_:to:force:) 是 slot 级 overlay 合并：默认不覆盖用户已设好的同一槽位，
//    force=true 才覆盖。gesture / layers 字典按子键逐项合并。

/// 一个可应用到 MappingConfig 的预设。
/// - bundleID == nil：层绑定类，并入 "global"（绑定通常写在 layers 槽）。
/// - bundleID != nil：per-app profile，并入对应 bundle 覆盖层。
struct Preset {
    let id: String
    let displayName: String   // 中文，给 M5 UI 预设库页展示
    let note: String          // 中文说明 / 待实测标记 / 接线提示
    let bundleID: String?
    let bindings: [String: KeyBinding]   // 遥控键名（RemoteKey.rawValue）→ 绑定
}

enum Presets {

    // 便捷构造：一个 key_stroke 动作。
    private static func ks(_ key: String, _ mods: [String] = []) -> Action {
        .keyStroke(key: key, mods: mods)
    }

    private static func switchAndFocus(_ systemAction: String) -> Action {
        .macro(steps: [.action(.system(systemAction)), .delay(ms: 250), .action(.focusInput)])
    }

    /// 老配置升级时补齐四向手势和 AI 层入口；slot 级合并不会覆盖用户已有设置。
    static let coreGestures = Preset(
        id: "core_gestures",
        displayName: "四向效率手势",
        note: "按住 OK + 方向触发四向手势。按住 TV 进入快捷控制模式；TV 双击进入/退出 AI 助手模式。",
        bundleID: nil,
        bindings: [
            "menu": KeyBinding(tap: .layerToggle(3),
                               layers: ["1": .system("next_app"), "3": .layerToggle(3)]),
            // 导航模式（菜单键点一下进入/退出）：切换后自动把光标送回输入位置。
            "left": KeyBinding(layers: ["1": .system("space_left"),
                                        "3": switchAndFocus("previous_app")]),
            "right": KeyBinding(layers: ["1": .system("space_right"),
                                         "3": switchAndFocus("next_app")]),
            "up": KeyBinding(layers: ["3": switchAndFocus("previous_app_window")]),
            "down": KeyBinding(layers: ["3": switchAndFocus("next_app_window")]),
            "ok": KeyBinding(gesture: [
                "up": .system("mission_control"),
                "down": .windowCycle(scope: "app"),
                "left": .tabJump(dir: -1, index: nil),
                "right": .tabJump(dir: 1, index: nil),
            ], layers: ["3": .focusInput]),
            "back": KeyBinding(layers: ["1": .system("previous_app"), "3": .system("space_left")]),
            "home": KeyBinding(layers: ["1": .system("show_desktop"), "2": ks("c", ["left_ctrl"]),
                                        "3": .system("space_right")]),
            "power": KeyBinding(layers: ["3": .system("show_desktop")]),
            "tv": KeyBinding(hold: .layerMomentary(1), double: .layerToggle(2),
                             layers: ["1": .system("app_expose"), "3": .system("app_expose")]),
        ]
    )

    // MARK: - 1) AI 批准层（用户点名核心）—— 层 2 的 global 绑定集
    //
    // 五家 AI CLI（Claude Code / Codex / Gemini / aider / opencode）的审批 UI 高度一致：
    // 编号/方向选项 + Enter 确认 + Esc 拒绝/中断，Shift+Tab 切自动模式。故一套层复用。
    // 键位依据：scratchpad/feature-menu.md §1A（权威查证表）。
    static let aiApprovalLayer = Preset(
        id: "ai_approval",
        displayName: "AI 助手模式（通用）",
        note: """
        双击 TV 开关 AI 助手模式：OK=批准(Enter/选第1项)、返回=Esc(拒绝/关弹窗)、\
        上下=选项导航、菜单=Shift+Tab 切自动模式、TV/音量+/−=数字 1/2/3 直选第 1/2/3 项。\
        主页键=Ctrl+C 中断，电源键=回到输入位置。适用于 Codex、Claude Code、Gemini、aider、opencode。
        """,
        bundleID: nil,
        bindings: [
            "ok":      KeyBinding(layers: ["2": ks("return")]),                 // 批准 / 选中项
            "back":    KeyBinding(layers: ["2": ks("escape")]),                // 拒绝 / 关弹窗 / 中断
            "up":      KeyBinding(layers: ["2": ks("up_arrow")]),              // 选项上移
            "down":    KeyBinding(layers: ["2": ks("down_arrow")]),            // 选项下移
            "menu":    KeyBinding(layers: ["2": ks("tab", ["left_shift"])]),   // Shift+Tab 切自动模式
            "home":    KeyBinding(layers: ["2": ks("c", ["left_ctrl"])]),      // 中断当前生成/任务
            "power":   KeyBinding(layers: ["2": .focusInput]),                  // 回到输入位置
            "tv":      KeyBinding(layers: ["2": ks("1")]),                     // 直选第 1 项（Yes）
            "volUp":   KeyBinding(layers: ["2": ks("2")]),                     // 直选第 2 项
            "volDown": KeyBinding(layers: ["2": ks("3")]),                     // 直选第 3 项
        ]
    )

    // MARK: - 2) 多 agent 窗口定位后批准 —— 层 2 内标签跳转
    //
    // 层 2 左/右 = 相对切标签（Ghostty / 浏览器 / VS Code 通吃 cmd+shift+[ / ]），
    // 配合 aiApprovalLayer，一个遥控管多个并行跑着的 agent：先切到目标标签，再 OK 批准。
    //
    // 「方向 + 数字直跳第 N 标签再批准」的组合宏示例（供 M5 UI 参考，未落为默认绑定）：
    //   跳到第 2 个标签并批准：
    //     {"type":"macro","steps":[
    //        {"type":"tab_jump","index":2},{"type":"delay","ms":80},{"type":"key_stroke","key":"return"}]}
    //   跳到第 3 个标签并批准：
    //     {"type":"macro","steps":[
    //        {"type":"tab_jump","index":3},{"type":"delay","ms":80},{"type":"key_stroke","key":"return"}]}
    static let multiAgentBindings = Preset(
        id: "multi_agent",
        displayName: "多 agent 定位批准",
        note: """
        AI 助手模式中左/右 = 上一个/下一个标签（cmd+shift+[ / ]，Ghostty/浏览器/VS Code 通用），\
        先定位到目标 agent 标签再按 OK 批准。
        """,
        bundleID: nil,
        bindings: [
            "left":  KeyBinding(layers: ["2": .tabJump(dir: -1, index: nil)]),  // 上一个标签
            "right": KeyBinding(layers: ["2": .tabJump(dir: 1, index: nil)]),   // 下一个标签
        ]
    )

    // MARK: - 3) AI 与高频工作场景 per-app 预设

    /// Ghostty 既承载 Codex CLI，也承载 Claude Code；这里直接提供 AI TUI 的日常操作。
    static let ghosttyAI = Preset(
        id: "ai_ghostty",
        displayName: "Ghostty · Codex / Claude Code",
        note: "左右切 Tab，上下选 CLI 选项，OK=确认、长按=Ctrl+C，返回=Esc、长按=Ctrl+U 清行。按住 TV + 方向切同一 Tab 内的 split；菜单键进入 App 导航模式。",
        bundleID: "com.mitchellh.ghostty",
        bindings: [
            "left": KeyBinding(tap: .tabJump(dir: -1, index: nil),
                               layers: ["1": ks("left_bracket", ["left_cmd"])]),
            "right": KeyBinding(tap: .tabJump(dir: 1, index: nil),
                                layers: ["1": ks("right_bracket", ["left_cmd"])]),
            "up": KeyBinding(tap: ks("up_arrow"),
                             layers: ["1": ks("up_arrow", ["left_cmd", "left_option"])]),
            "down": KeyBinding(tap: ks("down_arrow"),
                               layers: ["1": ks("down_arrow", ["left_cmd", "left_option"])]),
            "ok": KeyBinding(tap: ks("return"), hold: ks("c", ["left_ctrl"]), gesture: [
                "up": .system("mission_control"), "down": .windowCycle(scope: "app"),
                "left": .tabJump(dir: -1, index: nil), "right": .tabJump(dir: 1, index: nil),
            ], layers: ["1": ks("return", ["left_cmd", "left_shift"])]),
            "back": KeyBinding(tap: ks("escape"), hold: ks("u", ["left_ctrl"])),
            "menu": KeyBinding(tap: .layerToggle(3)),
            "home": KeyBinding(tap: .focusInput),
            "tv": KeyBinding(tap: ks("return", ["left_cmd", "left_shift"]),
                             hold: .layerMomentary(1), double: .layerToggle(2)),
        ]
    )

    static let codexDesktop = Preset(
        id: "ai_codex_desktop",
        displayName: "Codex 桌面版",
        note: "上下选择，左右切任务标签，OK=确认，返回=Esc，主页键聚焦输入框；菜单键进入 App 导航，TV 双击进入 AI 助手模式。",
        bundleID: "com.openai.codex",
        bindings: [
            "left": KeyBinding(tap: .tabJump(dir: -1, index: nil)),
            "right": KeyBinding(tap: .tabJump(dir: 1, index: nil)),
            "up": KeyBinding(tap: ks("up_arrow")),
            "down": KeyBinding(tap: ks("down_arrow")),
            "ok": KeyBinding(tap: ks("return"), gesture: [
                "up": .system("mission_control"), "down": .windowCycle(scope: "app"),
                "left": .tabJump(dir: -1, index: nil), "right": .tabJump(dir: 1, index: nil),
            ]),
            "back": KeyBinding(tap: ks("escape")),
            "menu": KeyBinding(tap: .layerToggle(3)),
            "home": KeyBinding(tap: .focusInput),
            "tv": KeyBinding(tap: ks("1"), hold: .layerMomentary(1), double: .layerToggle(2)),
        ]
    )

    static let chrome = Preset(
        id: "browser_chrome",
        displayName: "Google Chrome",
        note: "左右切标签，上下翻页，OK=确认，返回=浏览器后退，主页键=地址栏，菜单=新标签；OK 四向手势可切窗口和标签。",
        bundleID: "com.google.Chrome",
        bindings: [
            "left": KeyBinding(tap: .tabJump(dir: -1, index: nil)),
            "right": KeyBinding(tap: .tabJump(dir: 1, index: nil)),
            "up": KeyBinding(tap: ks("page_up")),
            "down": KeyBinding(tap: ks("page_down")),
            "ok": KeyBinding(tap: ks("return"), gesture: [
                "up": .system("mission_control"), "down": .windowCycle(scope: "app"),
                "left": .tabJump(dir: -1, index: nil), "right": .tabJump(dir: 1, index: nil),
            ]),
            "back": KeyBinding(tap: ks("left_bracket", ["left_cmd"])),
            "home": KeyBinding(tap: ks("l", ["left_cmd"])),
            "menu": KeyBinding(tap: .layerToggle(3), hold: ks("t", ["left_cmd"])),
        ]
    )

    static let claudeDesktop = Preset(
        id: "ai_claude_desktop",
        displayName: "Claude 桌面版",
        note: "上下选择，左右切标签，OK=确认，返回=Esc，主页键聚焦输入框；菜单键进入 App 导航，TV 双击进入 AI 助手模式。",
        bundleID: "com.anthropic.claudefordesktop",
        bindings: [
            "left": KeyBinding(tap: .tabJump(dir: -1, index: nil)),
            "right": KeyBinding(tap: .tabJump(dir: 1, index: nil)),
            "up": KeyBinding(tap: ks("up_arrow")),
            "down": KeyBinding(tap: ks("down_arrow")),
            "ok": KeyBinding(tap: ks("return"), gesture: [
                "up": .system("mission_control"), "down": .windowCycle(scope: "app"),
                "left": .tabJump(dir: -1, index: nil), "right": .tabJump(dir: 1, index: nil),
            ]),
            "back": KeyBinding(tap: ks("escape")),
            "menu": KeyBinding(tap: .layerToggle(3)),
            "home": KeyBinding(tap: .focusInput),
            "tv": KeyBinding(tap: ks("1"), hold: .layerMomentary(1), double: .layerToggle(2)),
        ]
    )

    static let safari = Preset(
        id: "browser_safari",
        displayName: "Safari",
        note: "左右切标签，上下翻页，OK=确认，返回=后退，主页键=地址栏，菜单=新标签；OK 四向手势可切窗口和标签。",
        bundleID: "com.apple.Safari",
        bindings: [
            "left": KeyBinding(tap: .tabJump(dir: -1, index: nil)),
            "right": KeyBinding(tap: .tabJump(dir: 1, index: nil)),
            "up": KeyBinding(tap: ks("page_up")),
            "down": KeyBinding(tap: ks("page_down")),
            "ok": KeyBinding(tap: ks("return"), gesture: [
                "up": .system("mission_control"), "down": .windowCycle(scope: "app"),
                "left": .tabJump(dir: -1, index: nil), "right": .tabJump(dir: 1, index: nil),
            ]),
            "back": KeyBinding(tap: ks("left_bracket", ["left_cmd"])),
            "home": KeyBinding(tap: ks("l", ["left_cmd"])),
            "menu": KeyBinding(tap: .layerToggle(3), hold: ks("t", ["left_cmd"])),
        ]
    )

    static let weChat = Preset(
        id: "chat_wechat",
        displayName: "微信",
        note: "上下浏览会话/消息，OK=发送，返回=Esc，主页键=搜索，菜单=新建聊天；OK+上下切窗口/调度中心。",
        bundleID: "com.tencent.xinWeChat",
        bindings: [
            "up": KeyBinding(tap: ks("up_arrow")),
            "down": KeyBinding(tap: ks("down_arrow")),
            "left": KeyBinding(tap: ks("page_up")),
            "right": KeyBinding(tap: ks("page_down")),
            "ok": KeyBinding(tap: ks("return"), gesture: [
                "up": .system("mission_control"), "down": .windowCycle(scope: "app"),
                "left": .tabJump(dir: -1, index: nil), "right": .tabJump(dir: 1, index: nil),
            ]),
            "back": KeyBinding(tap: ks("escape")),
            "home": KeyBinding(tap: ks("f", ["left_cmd"])),
            "menu": KeyBinding(tap: .layerToggle(3), hold: ks("n", ["left_cmd"])),
        ]
    )

    static let workPresets: [Preset] = [ghosttyAI, codexDesktop, chrome, safari, claudeDesktop, weChat]

    // MARK: - 4) 媒体 + 演示 per-app 预设
    //
    // YouTube 走浏览器（前台是 Chrome/Safari 而非 youtube.com，profile 无法按网页判定），
    // 故不做专用预设；如需可让用户在浏览器 profile 里手配 空格/J/L/F/C。

    /// IINA 播放器
    static let iina = Preset(
        id: "media_iina",
        displayName: "IINA 播放器",
        note: "OK=空格 播放/暂停，左右=←/→ 快退/快进，上=F 全屏，菜单=Ctrl+Shift+S 字幕开关。",
        bundleID: "com.colliderli.iina",
        bindings: [
            "ok":   KeyBinding(tap: ks("space")),
            "left": KeyBinding(tap: ks("left_arrow")),
            "right":KeyBinding(tap: ks("right_arrow")),
            "up":   KeyBinding(tap: ks("f")),
            "menu": KeyBinding(tap: .layerToggle(3), hold: ks("s", ["left_ctrl", "left_shift"])),
        ]
    )

    /// VLC 播放器
    static let vlc = Preset(
        id: "media_vlc",
        displayName: "VLC 播放器",
        note: "OK=空格 播放/暂停，左右=Cmd+Opt+←/→ 快退/快进 10s，上=Cmd+F 全屏，菜单=S 字幕切轨。",
        bundleID: "org.videolan.vlc",
        bindings: [
            "ok":   KeyBinding(tap: ks("space")),
            "left": KeyBinding(tap: ks("left_arrow", ["left_cmd", "left_option"])),
            "right":KeyBinding(tap: ks("right_arrow", ["left_cmd", "left_option"])),
            "up":   KeyBinding(tap: ks("f", ["left_cmd"])),
            "menu": KeyBinding(tap: .layerToggle(3), hold: ks("s")),
        ]
    )

    /// Keynote 演示
    static let keynote = Preset(
        id: "present_keynote",
        displayName: "Keynote 演示",
        note: "左右=上一页/下一页，OK=Cmd+Opt+P 开始放映，菜单=B 黑屏（再按恢复）。",
        bundleID: "com.apple.iWork.Keynote",
        bindings: [
            "left": KeyBinding(tap: ks("left_arrow")),
            "right":KeyBinding(tap: ks("right_arrow")),
            "ok":   KeyBinding(tap: ks("p", ["left_cmd", "left_option"])),
            "menu": KeyBinding(tap: .layerToggle(3), hold: ks("b")),
        ]
    )

    /// PowerPoint 演示
    static let powerpoint = Preset(
        id: "present_powerpoint",
        displayName: "PowerPoint 演示",
        note: "左右=上一页/下一页，OK=F5 开始放映，菜单=B 黑屏（再按恢复）。",
        bundleID: "com.microsoft.Powerpoint",
        bindings: [
            "left": KeyBinding(tap: ks("left_arrow")),
            "right":KeyBinding(tap: ks("right_arrow")),
            "ok":   KeyBinding(tap: ks("f5")),
            "menu": KeyBinding(tap: .layerToggle(3), hold: ks("b")),
        ]
    )

    static let mediaPresets: [Preset] = [iina, vlc, keynote, powerpoint]

    // MARK: - 5) 会议急救预设
    //
    // Zoom 快捷键已核实（Cmd+Shift+A 静音、Cmd+Shift+V 摄像头）。
    // 腾讯会议 / 飞书的静音快捷键与 bundle id 官方文档未明确 → 标「待实测」，
    // 暂用与 Zoom 一致的合理默认（Cmd+Shift+A），接线前建议实机确认。

    /// Zoom：TV=静音，TV 双击=开关摄像头
    static let zoom = Preset(
        id: "meeting_zoom",
        displayName: "Zoom 会议",
        note: "TV=Cmd+Shift+A 麦克风静音/取消，TV 双击=Cmd+Shift+V 摄像头开关。",
        bundleID: "us.zoom.xos",
        bindings: [
            "tv": KeyBinding(tap: ks("a", ["left_cmd", "left_shift"]),
                             double: ks("v", ["left_cmd", "left_shift"])),
        ]
    )

    /// 腾讯会议：TV=静音（快捷键待实测）
    static let tencentMeeting = Preset(
        id: "meeting_tencent",
        displayName: "腾讯会议",
        note: "TV=麦克风静音。快捷键【待实测】，暂用 Cmd+Shift+A（与 Zoom 一致的合理默认），接线前请实机确认。",
        bundleID: "com.tencent.meeting",
        bindings: [
            "tv": KeyBinding(tap: ks("a", ["left_cmd", "left_shift"])),
        ]
    )

    /// 飞书：TV=静音（bundle id 与快捷键均待实测）
    static let feishu = Preset(
        id: "meeting_feishu",
        displayName: "飞书会议",
        note: "TV=麦克风静音。bundle id（com.electron.lark）与快捷键均【待实测】，暂用 Cmd+Shift+A 默认，接线前请实机确认。",
        bundleID: "com.electron.lark",
        bindings: [
            "tv": KeyBinding(tap: ks("a", ["left_cmd", "left_shift"])),
        ]
    )

    static let meetingPresets: [Preset] = [zoom, tencentMeeting, feishu]

    // MARK: - 汇总
    static let layerPresets: [Preset] = [coreGestures, aiApprovalLayer, multiAgentBindings]
    static let all: [Preset] = workPresets + layerPresets + mediaPresets + meetingPresets

    // MARK: - apply：slot 级 overlay 合并
    //
    /// 把一个预设合并进配置。bundleID==nil 并入 "global"，否则并入对应 bundle 覆盖层。
    /// 默认不覆盖用户已设好的同一槽位（tap/hold/double/单个 gesture 方向/单个 layer）；
    /// force=true 时预设值一律覆盖。目标 profile / 目标键不存在则创建。
    static func apply(_ preset: Preset, to config: inout MappingConfig, force: Bool = false) {
        let profileKey = preset.bundleID ?? "global"
        var profile = config.profiles[profileKey] ?? [:]
        for (remoteKey, presetBinding) in preset.bindings {
            var existing = profile[remoteKey] ?? KeyBinding()
            merge(presetBinding, into: &existing, force: force)
            profile[remoteKey] = existing
        }
        config.profiles[profileKey] = profile
    }

    /// 单键 slot 级合并：仅在目标槽为空（或 force）时写入预设值。
    private static func merge(_ src: KeyBinding, into dst: inout KeyBinding, force: Bool) {
        if let v = src.tap,    force || dst.tap == nil    { dst.tap = v }
        if let v = src.hold,   force || dst.hold == nil   { dst.hold = v }
        if let v = src.double, force || dst.double == nil { dst.double = v }
        if let g = src.gesture {
            var merged = dst.gesture ?? [:]
            for (dir, act) in g where force || merged[dir] == nil { merged[dir] = act }
            dst.gesture = merged
        }
        if let l = src.layers {
            var merged = dst.layers ?? [:]
            for (layer, act) in l where force || merged[layer] == nil { merged[layer] = act }
            dst.layers = merged
        }
    }

    // MARK: - selfCheck 支撑：遍历预设内所有 Action
    /// 展平一个 KeyBinding 的全部动作（含 gesture / layers 值），供键名查证。
    static func actions(in binding: KeyBinding) -> [Action] {
        var out: [Action] = []
        if let a = binding.tap { out.append(a) }
        if let a = binding.hold { out.append(a) }
        if let a = binding.double { out.append(a) }
        binding.gesture?.values.forEach { out.append($0) }
        binding.layers?.values.forEach { out.append($0) }
        return out
    }
}
