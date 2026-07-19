import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - resilience 模块适配

protocol LoginItemManaging {
    var isEnabled: Bool { get }
    /// 返回是否设置成功。
    @discardableResult func setEnabled(_ on: Bool) -> Bool
}

struct SystemLoginItemManager: LoginItemManaging {
    var isEnabled: Bool { LoginItem.isEnabled }
    @discardableResult func setEnabled(_ on: Bool) -> Bool {
        LoginItem.run(on ? .on : .off).code == 0
    }
}

// MARK: - App 级偏好（UserDefaults，ui-spec §7 字段归属表）

enum VoiceMode: String, CaseIterable {
    case remoteMic, macMic, off
}

enum Prefs {
    static let voiceMode      = "com.miremote.pref.voiceMode"
    static let voiceGainDb    = "com.miremote.pref.voiceGainDb"
    static let showStatusItem = "com.miremote.pref.showStatusItem"
    static let feedbackSound  = "com.miremote.pref.feedbackSound"
    static let seizeDevice    = "com.miremote.pref.seizeDevice"
    static let exitConfirm    = "com.miremote.pref.exitConfirm"
    static let onboardingDone = "com.miremote.pref.hasCompletedOnboarding"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            voiceMode: VoiceMode.remoteMic.rawValue,
            voiceGainDb: 0.0,
            showStatusItem: true,
            feedbackSound: false,
            seizeDevice: true,
            exitConfirm: true,
            onboardingDone: false,
        ])
    }
}

// MARK: - 遥控键展示元数据（映射页 KeyEditor / 学习模式）

enum KeyDisplay {
    /// (中文名, usage 说明, 徽标短名)
    static let info: [RemoteKey: (name: String, usage: String, badge: String)] = [
        .power:   ("电源键", "HID usage 0x66", "⏻"),
        .voice:   ("语音键", "键盘页 F5 (0x3E)", "🎙"),
        .up:      ("方向键 · 上", "HID usage 0x52", "↑"),
        .down:    ("方向键 · 下", "HID usage 0x51", "↓"),
        .left:    ("方向键 · 左", "HID usage 0x50", "←"),
        .right:   ("方向键 · 右", "HID usage 0x4F", "→"),
        .ok:      ("确认键（方向环中心）", "HID usage 0x28", "OK"),
        .back:    ("返回键", "HID usage 0xF1", "返回"),
        .menu:    ("菜单键", "HID usage 0x65", "菜单"),
        .home:    ("主页键", "HID usage 0x4A", "主页"),
        .tv:      ("TV 自定义键", "HID usage 0x35", "TV"),
        .volUp:   ("音量 ＋", "HID usage 0x80", "Vol+"),
        .volDown: ("音量 －", "HID usage 0x81", "Vol−"),
    ]
    static func name(_ k: RemoteKey) -> String { info[k]?.name ?? k.rawValue }
    static func badge(_ k: RemoteKey) -> String { info[k]?.badge ?? k.rawValue }
    static func usage(_ k: RemoteKey) -> String { info[k]?.usage ?? "" }

    /// 自测：13 键元数据齐备。
    static func selfCheck() -> Bool {
        RemoteKey.allCases.allSatisfy { info[$0] != nil }
    }
}

// MARK: - Action 人类可读摘要（ActionPicker 关闭态 / 预设预览表共用，纯函数可测）

enum ActionSummary {

    private static let baseSystemNames: [(value: String, display: String)] = [
        ("volume_up", "音量 ＋"), ("volume_down", "音量 －"), ("mute", "静音"),
        ("play_pause", "播放/暂停"), ("next", "下一曲"), ("prev", "上一曲"),
        ("mission_control", "调度中心"), ("launchpad", "启动台"), ("spotlight", "Spotlight"),
        ("display_sleep", "显示器睡眠"), ("lock_screen", "锁屏"), ("screenshot", "截图"),
    ]
    static let systemNames: [(value: String, display: String)] = baseSystemNames
        + WorkspaceActions.descriptors
            .filter { !Set(baseSystemNames.map(\.value)).contains($0.action.rawValue) }
            .map { ($0.action.rawValue, $0.title) }
    static func systemDisplay(_ v: String) -> String {
        systemNames.first(where: { $0.value == v })?.display ?? v
    }

    /// 修饰键名 → 符号（右修饰追加「（右）」标注在整体摘要末尾）。
    private static let modSymbol: [String: String] = [
        "left_cmd": "⌘", "right_cmd": "⌘",
        "left_shift": "⇧", "right_shift": "⇧",
        "left_option": "⌥", "right_option": "⌥",
        "left_ctrl": "⌃", "right_ctrl": "⌃",
    ]
    private static let keyPretty: [String: String] = [
        "return": "Return ⏎", "enter": "Enter", "tab": "Tab ⇥", "space": "Space",
        "delete": "Delete ⌫", "escape": "Esc ⎋", "esc": "Esc ⎋",
        "up_arrow": "↑", "down_arrow": "↓", "left_arrow": "←", "right_arrow": "→",
    ]

    static func keyStrokeSummary(key: String, mods: [String]) -> String {
        // 顺序：⌃⌥⇧⌘ 的 mac 惯例
        let order = ["left_ctrl", "right_ctrl", "left_option", "right_option",
                     "left_shift", "right_shift", "left_cmd", "right_cmd"]
        let sorted = mods.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        let symbols = sorted.compactMap { modSymbol[$0] }.joined()
        let main = keyPretty[key.lowercased()] ?? key.uppercased()
        let rightMark = sorted.contains(where: { $0.hasPrefix("right_") }) ? "（右）" : ""
        return symbols + main + rightMark
    }

    static func describe(_ action: Action?) -> String {
        guard let action else { return "无" }
        switch action {
        case .none:                     return "无"
        case .keyStroke(let k, let m):  return "发送按键 · \(keyStrokeSummary(key: k, mods: m))"
        case .system(let v):            return systemDisplay(v)
        case .openApp(let bundle):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                return "打开 \(FileManager.default.displayName(atPath: url.path))"
            }
            return "打开应用 · \(bundle)"
        case .shell(let cmd):           return "Shell · \(cmd.count > 24 ? String(cmd.prefix(24)) + "…" : cmd)"
        case .voice:                    return "语音输入"
        case .layerMomentary(let n):    return "按住进入\(modeDisplayName(n))"
        case .layerToggle(let n):       return "开关\(modeDisplayName(n))"
        case .windowCycle(let scope):   return scope == "global" ? "窗口循环（全局）" : "窗口循环（同应用）"
        case .tabJump(let dir, let idx):
            if let idx { return "跳到第 \(idx) 个标签页" }
            return (dir ?? 1) >= 0 ? "下一个标签页" : "上一个标签页"
        case .focusInput:               return "聚焦输入框"
        case .mouseMode:                return "鼠标模式开关"
        case .macro(let steps):         return "宏（\(steps.count) 步）"
        }
    }

    /// 自测（不依赖 AppKit 查询路径的分支）。
    static func selfCheck() -> Bool {
        describe(nil) == "无"
            && describe(.keyStroke(key: "return", mods: [])) == "发送按键 · Return ⏎"
            && describe(.keyStroke(key: "k", mods: ["right_option"])) == "发送按键 · ⌥K（右）"
            && describe(.system("mission_control")) == "调度中心"
            && describe(.layerMomentary(1)) == "按住进入快捷控制模式"
            && describe(.tabJump(dir: -1, index: nil)) == "上一个标签页"
    }
}

func modeDisplayName(_ number: Int) -> String {
    switch number {
    case 1: return "快捷控制模式"
    case 2: return "AI 助手模式"
    case 3: return "App 导航模式"
    default: return "自定义模式 \(number)"
    }
}

// MARK: - AppModel

/// UI 数据中枢：MappingConfig 读写 + App 级偏好 + 运行时状态镜像。
/// 写回 config.json 后调用引擎 setConfig 热加载（UI 自己写自己知道，不做 FSEvents）。
@MainActor
final class AppModel: ObservableObject {

    // 映射配置
    @Published var config: MappingConfig
    @Published var selectedKey: RemoteKey = .ok
    @Published var currentProfile: String = "global"

    // 运行时状态（服务回调镜像，主线程更新）
    @Published var connected = false
    @Published var deviceName: String?
    @Published var activeLayer = 0
    @Published var voiceActive = false
    @Published var batteryPercent: Int?
    @Published var mouseModeActive = false
    @Published var degraded = false          // tap 失效等故障态
    @Published var levelBars: [Float] = Array(repeating: 0, count: 12)
    /// 最近一次按下的遥控键（「按下即亮」回显），nil=无
    @Published var lastPressedKey: RemoteKey?
    /// inline「已保存」微提示（自增触发）
    @Published var savedTick = 0

    // App 级偏好（UserDefaults）
    @Published var voiceMode: VoiceMode { didSet { prefsChanged() } }
    @Published var voiceGainDb: Double { didSet { prefsChanged() } }
    @Published var showStatusItem: Bool { didSet { prefsChanged() } }
    @Published var feedbackSound: Bool { didSet { prefsChanged() } }
    @Published var seizeDevice: Bool { didSet { prefsChanged() } }
    @Published var exitConfirm: Bool { didSet { prefsChanged() } }
    @Published var hasCompletedOnboarding: Bool { didSet { prefsChanged() } }

    // 依赖
    let configURL: URL
    weak var services: AppServices?
    let loginItems: LoginItemManaging

    /// 预设套用的一次 undo 快照
    private(set) var presetUndoSnapshot: MappingConfig?

    private var mousePollTimer: Timer?
    private var flashWork: DispatchWorkItem?

    init(configURL: URL = ConfigStore.defaultURL(),
         services: AppServices? = nil,
         loginItems: LoginItemManaging = SystemLoginItemManager()) {
        Prefs.registerDefaults()
        self.configURL = configURL
        self.services = services
        self.loginItems = loginItems
        let d = UserDefaults.standard
        self.voiceMode = VoiceMode(rawValue: d.string(forKey: Prefs.voiceMode) ?? "") ?? .remoteMic
        self.voiceGainDb = d.double(forKey: Prefs.voiceGainDb)
        self.showStatusItem = d.bool(forKey: Prefs.showStatusItem)
        self.feedbackSound = d.bool(forKey: Prefs.feedbackSound)
        self.seizeDevice = d.bool(forKey: Prefs.seizeDevice)
        self.exitConfirm = d.bool(forKey: Prefs.exitConfirm)
        self.hasCompletedOnboarding = d.bool(forKey: Prefs.onboardingDone)
        if let loaded = ConfigStore.load(from: configURL) {
            let migrated = migrateConfigIfNeeded(loaded)
            self.config = migrated
            if migrated.version != loaded.version { _ = ConfigStore.save(migrated, to: configURL) }
        } else {
            self.config = defaultConfig()
        }

        // 鼠标模式无回调 API，0.5s 轮询 isActive（低频，可接受）。
        mousePollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let active = MouseMode.shared.isActive
                if active != self.mouseModeActive { self.mouseModeActive = active }
            }
        }
    }

    // MARK: 偏好写回

    private func prefsChanged() {
        let d = UserDefaults.standard
        d.set(voiceMode.rawValue, forKey: Prefs.voiceMode)
        d.set(voiceGainDb, forKey: Prefs.voiceGainDb)
        d.set(showStatusItem, forKey: Prefs.showStatusItem)
        d.set(feedbackSound, forKey: Prefs.feedbackSound)
        d.set(seizeDevice, forKey: Prefs.seizeDevice)
        d.set(exitConfirm, forKey: Prefs.exitConfirm)
        d.set(hasCompletedOnboarding, forKey: Prefs.onboardingDone)
        applyVoiceMode()
    }

    /// 语音模式 → VoiceBridgeApp 开关（A=切BlackHole+豆包 / B=仅豆包 / off=全关）。
    func applyVoiceMode() {
        guard let voice = services?.voiceApp else { return }
        switch voiceMode {
        case .remoteMic: voice.switchInput = true;  voice.doubao = true
        case .macMic:    voice.switchInput = false; voice.doubao = true
        case .off:       voice.switchInput = false; voice.doubao = false
        }
    }

    // MARK: 映射配置读写

    /// 当前 profile 中某键的绑定（不存在返回空绑定）。
    func binding(for key: RemoteKey) -> KeyBinding {
        config.profiles[currentProfile]?[key.rawValue] ?? KeyBinding()
    }

    /// 修改当前 profile 中某键的绑定并立即写回 + 热加载。
    func updateBinding(for key: RemoteKey, _ mutate: (inout KeyBinding) -> Void) {
        var profile = config.profiles[currentProfile] ?? [:]
        var b = profile[key.rawValue] ?? KeyBinding()
        mutate(&b)
        profile[key.rawValue] = b
        config.profiles[currentProfile] = profile
        saveConfig()
    }

    /// App 未单独配置语音快捷键时继承全局；全局缺失则使用安全默认值。
    func voiceRule(for profile: String) -> VoiceTriggerRule {
        config.voiceProfiles?[profile]
            ?? config.voiceProfiles?["global"]
            ?? VoiceTriggerRule()
    }

    func hasCustomVoiceRule(for profile: String) -> Bool {
        profile == "global" || config.voiceProfiles?[profile] != nil
    }

    func updateVoiceRule(for profile: String, _ mutate: (inout VoiceTriggerRule) -> Void) {
        var rules = config.voiceProfiles ?? [:]
        var rule = rules[profile] ?? rules["global"] ?? VoiceTriggerRule()
        mutate(&rule)
        rules[profile] = rule
        config.voiceProfiles = rules
        saveConfig()
    }

    func resetVoiceRuleToGlobal(for profile: String) {
        guard profile != "global" else { return }
        config.voiceProfiles?.removeValue(forKey: profile)
        saveConfig()
    }

    /// 写回 config.json → 引擎热加载 → inline「已保存」提示。
    func saveConfig() {
        if ConfigStore.save(config, to: configURL) {
            services?.applyConfig(config)
            savedTick += 1
        }
    }

    // MARK: 预设

    /// 套用预设（onlyFillEmpty=true 仅填空位）。保留一次 undo 快照。
    func applyPreset(_ preset: Preset, to profileName: String?, onlyFillEmpty: Bool) {
        presetUndoSnapshot = config
        var cfg = config
        if let profileName, preset.bundleID == nil, profileName != "global" {
            // 层类预设指定套到某 profile：手动合并
            var p = cfg.profiles[profileName] ?? [:]
            for (k, b) in preset.bindings {
                var dst = p[k] ?? KeyBinding()
                mergeBinding(b, into: &dst, force: !onlyFillEmpty)
                p[k] = dst
            }
            cfg.profiles[profileName] = p
        } else {
            Presets.apply(preset, to: &cfg, force: !onlyFillEmpty)
        }
        config = cfg
        saveConfig()
    }

    private func mergeBinding(_ src: KeyBinding, into dst: inout KeyBinding, force: Bool) {
        if let v = src.tap, force || dst.tap == nil { dst.tap = v }
        if let v = src.hold, force || dst.hold == nil { dst.hold = v }
        if let v = src.double, force || dst.double == nil { dst.double = v }
        if let g = src.gesture {
            var m = dst.gesture ?? [:]
            for (k, v) in g where force || m[k] == nil { m[k] = v }
            dst.gesture = m
        }
        if let l = src.layers {
            var m = dst.layers ?? [:]
            for (k, v) in l where force || m[k] == nil { m[k] = v }
            dst.layers = m
        }
    }

    /// 撤销上一次预设套用。
    func undoPresetApply() {
        guard let snap = presetUndoSnapshot else { return }
        presetUndoSnapshot = nil
        config = snap
        saveConfig()
    }

    // MARK: 运行时事件（AppDelegate 接线调用，均已在主线程）

    func noteConnection(_ ok: Bool, name: String?) {
        connected = ok
        deviceName = ok ? name : deviceName
        if !ok { batteryPercent = nil }
    }

    func noteLayer(_ layer: Int) {
        let entering = layer != 0
        activeLayer = layer
        if feedbackSound {
            NSSound(named: entering ? "Tink" : "Bottle")?.play()
        }
    }

    func noteVoice(_ active: Bool) { voiceActive = active }
    func noteBattery(_ pct: Int) { batteryPercent = pct }
    func noteSeize(_ ok: Bool) { degraded = !ok }

    func runHealthRepair() -> String {
        guard let report = services?.runRepair() else { return "引擎未运行，已跳过运行时修复" }
        return report.lines().joined(separator: "；")
    }

    func noteLevel(_ rms: Float) {
        var bars = levelBars
        bars.removeFirst()
        bars.append(rms)
        levelBars = bars
    }

    /// 「按下即亮」：记录最近按键并 0.3s 后熄灭。
    func noteButton(_ event: ButtonEvent) {
        guard event.isDown else { return }
        lastPressedKey = event.key
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lastPressedKey = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
