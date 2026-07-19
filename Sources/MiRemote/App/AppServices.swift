import Foundation
import AppKit

// M5：把原 main.swift 的接线逻辑抽成可复用的服务容器，
// CLI 模式与 GUI 模式共用同一套接线，不复制两份。

func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func log(_ msg: String) {
    FileHandle.standardError.write("[\(ts())] \(msg)\n".data(using: .utf8)!)
}

// MARK: - 配置读写（ConfigStore：UI 与 CLI 共用，路径可注入便于自测）

enum ConfigStore {
    /// 默认配置文件 URL（~/Library/Application Support/MiRemote/config.json）
    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 读配置；解析失败返回 nil（调用方决定回退策略，原文件保留未动）。
    static func load(from url: URL) -> MappingConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MappingConfig.self, from: data)
    }

    /// 只读加载（文件不存在或解析失败返回 nil，绝不创建文件）。
    /// 启动早期读 settings（遥控器 VID/PID、声卡名等）用——语音-only 模式不应因此落盘配置。
    static func loadIfExists(at path: String?) -> MappingConfig? {
        load(from: path.map { URL(fileURLWithPath: $0) } ?? defaultURL())
    }

    /// 写配置（pretty + sortedKeys，便于用户手改与 diff）。
    @discardableResult
    static func save(_ config: MappingConfig, to url: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log("配置写入失败: \(error)")
            return false
        }
    }
}

func loadOrCreateConfig(at path: String? = nil) -> MappingConfig {
    let url = path.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultURL()
    if FileManager.default.fileExists(atPath: url.path) {
        if let loaded = ConfigStore.load(from: url) {
            let cfg = migrateConfigIfNeeded(loaded)
            if cfg.version != loaded.version, ConfigStore.save(cfg, to: url) {
                log("配置已升级到 v\(cfg.version)，已补齐内置 Profile（用户已有绑定保持不变）")
            }
            log("配置已加载: \(url.path)")
            return cfg
        }
        // Action 严格解码：未知 type/缺字段会走到这里。明确告知回退，绝不静默。
        log("配置解析失败，使用默认配置（原文件保留未动）: \(url.path)")
        return defaultConfig()   // 不覆盖用户的问题文件，便于修复
    }
    let cfg = defaultConfig()
    if ConfigStore.save(cfg, to: url) {
        log("已生成默认配置: \(url.path)")
    }
    return cfg
}

/// 分阶段迁移；每一阶段只执行一次，用户日后主动删除的 Profile 不会被补回。
func migrateConfigIfNeeded(_ input: MappingConfig) -> MappingConfig {
    guard input.version < MappingConfig.currentVersion else { return input }
    var cfg = input
    if cfg.version < 2 {
        if cfg.profiles["global"] == nil { cfg.profiles["global"] = [:] }
        for preset in Presets.all { Presets.apply(preset, to: &cfg) }
        // 导航交互的明确入口：菜单键点按开关导航模式。
        var menu = cfg.profiles["global"]?["menu"] ?? KeyBinding()
        menu.tap = .layerToggle(3)
        cfg.profiles["global"]?["menu"] = menu
        if cfg.settings.doubleMs < 150 { cfg.settings.doubleMs = 250 }
        cfg.version = 2
    }
    if cfg.version < 3 {
        var rules = cfg.voiceProfiles ?? [:]
        if rules["global"] == nil { rules["global"] = VoiceTriggerRule() }
        cfg.voiceProfiles = rules
        cfg.version = 3
    }
    if cfg.version < 4 {
        migrateToMentalModelV2(&cfg)
        cfg.version = 4
    }
    return cfg
}

/// v4：按键心智模型 v2（DESIGN §3.1b）。系统导航键（Home/菜单/TV）的 base 槽位
/// 是心智模型的骨架，强制改写到 v2 语义；用户其余自定义（层内/手势/per-app）保留。
func migrateToMentalModelV2(_ cfg: inout MappingConfig) {
    var g = cfg.profiles["global"] ?? [:]

    var home = g["home"] ?? KeyBinding()
    home.tap = .system("show_desktop")          // 零延迟显示桌面（键帽语义就近）
    home.hold = .overlay("tutorial")            // 当前 App 映射教程浮层
    home.double = nil
    g["home"] = home

    var menu = g["menu"] ?? KeyBinding()
    menu.tap = .overlay("window_picker")        // 窗口选择器浮层
    menu.hold = .overlay("system_menu")         // 完整系统功能菜单浮层
    menu.double = nil
    g["menu"] = menu

    var tv = g["tv"] ?? KeyBinding()
    tv.tap = .layerToggle(2)                    // 进/出 App 控制模式（层2 + HUD）
    tv.hold = .overlay("app_wheel")             // App 轮盘（停留式，DESIGN §3.1b）
    tv.double = nil                             // v2 双击不定义（TV 双击切层已被控制模式取代）
    // 层2 内 TV 不再直选数字：留空让 tap 回退 layerToggle(2)，保证「再按 TV 退出模式」。
    tv.layers?.removeValue(forKey: "2")
    g["tv"] = tv

    // 零同按原则（DESIGN §3.1b）：默认不再注入 OK hold=瞬时层；用户已设的 hold 保留。

    // 层2 音量± 由旧「数字 2/3 直选」改为「切 Agent（上一个/下一个标签）」。
    var volUp = g["volUp"] ?? KeyBinding()
    if volUp.tap == nil { volUp.tap = .system("volume_up") }
    if volUp.layers?["2"] == .keyStroke(key: "2", mods: []) {
        volUp.layers?["2"] = .tabJump(dir: 1, index: nil)
    }
    g["volUp"] = volUp
    var volDown = g["volDown"] ?? KeyBinding()
    if volDown.tap == nil { volDown.tap = .system("volume_down") }
    if volDown.layers?["2"] == .keyStroke(key: "3", mods: []) {
        volDown.layers?["2"] = .tabJump(dir: -1, index: nil)
    }
    g["volDown"] = volDown

    cfg.profiles["global"] = g

    // per-app 清理：旧预设的「TV 双击=layer_toggle(2)」与旧 TV tap 接线让位给控制模式。
    let staleTvTaps: [Action] = [
        .keyStroke(key: "return", mods: ["left_cmd", "left_shift"]),   // 旧 Ghostty 预设
        .keyStroke(key: "1", mods: []),                                 // 旧 Codex/Claude 桌面预设
    ]
    for (name, profile) in cfg.profiles where name != "global" {
        guard var tvB = profile["tv"] else { continue }
        if tvB.double == .layerToggle(2) { tvB.double = nil }
        if let tap = tvB.tap, staleTvTaps.contains(tap) { tvB.tap = nil }
        var p = profile
        p["tv"] = tvB
        cfg.profiles[name] = p
    }
}

func defaultConfig() -> MappingConfig {
    // 默认配置 = 按键心智模型 v2（DESIGN §3.1b，2026-07-19 定稿）：
    //   内容操作：方向/OK/返回原生直通（引擎保护）。
    //   同级切换：音量± = 系统音量（跟键帽一致）；控制模式内 = 切 Agent/标签。
    //   系统导航：Home 单击=显示桌面（零延迟）、长按=映射教程浮层；
    //             菜单单击=窗口选择器浮层、长按=系统功能菜单浮层。
    //   App 专用：TV 单击=进/出 App 控制模式（层2+HUD）、长按=App 轮盘浮层（停留式）。
    //   零同按组合：单手拇指操作，「按住 A 再按 B」（OK+方向手势、OK 长按瞬时层）
    //   不进默认配置；引擎能力保留，供高级用户自配。层1 数据保留但默认无入口。
    var cfg = MappingConfig()
    cfg.voiceProfiles = ["global": VoiceTriggerRule()]
    cfg.profiles["global"] = [
        "up":      KeyBinding(tap: .keyStroke(key: "up_arrow", mods: []),
                              layers: ["1": .system("volume_up")]),
        "down":    KeyBinding(tap: .keyStroke(key: "down_arrow", mods: []),
                              layers: ["1": .system("volume_down")]),
        "left":    KeyBinding(tap: .keyStroke(key: "left_arrow", mods: [])),
        "right":   KeyBinding(tap: .keyStroke(key: "right_arrow", mods: [])),
        "ok":      KeyBinding(tap: .keyStroke(key: "return", mods: [])),
        "back":    KeyBinding(tap: .keyStroke(key: "delete", mods: []),
                              layers: ["1": .system("previous_app")]),
        "menu":    KeyBinding(tap: .overlay("window_picker"),
                              hold: .overlay("system_menu"),
                              layers: ["1": .system("next_app")]),
        "home":    KeyBinding(tap: .system("show_desktop"),
                              hold: .overlay("tutorial"),
                              layers: ["1": .system("mission_control")]),
        // TV 单击 = 进/出 App 控制模式（层2；HUD 由 GUI 随层变化显示）；
        // 长按 = App 轮盘浮层（停留式：弹出后可松手，方向选、OK/再按 TV 确认、
        // 返回取消、3s 超时自关；浮层打开期间按键走 uiCapture 路由，UI 侧实现）。
        "tv":      KeyBinding(tap: .layerToggle(2),
                              hold: .overlay("app_wheel"),
                              layers: ["1": .system("app_expose")]),
        // 电源长按 = 鼠标模式开关（P4：给 mouse_mode 一个开箱可达的默认入口；
        // 方向键移动指针、OK=左键。tap 保持键帽语义的显示器睡眠）。
        "power":   KeyBinding(tap: .system("display_sleep"), hold: .mouseMode),
        "volUp":   KeyBinding(tap: .system("volume_up")),
        "volDown": KeyBinding(tap: .system("volume_down")),
        "voice":   KeyBinding(tap: .voice),
    ]
    // 内置预设并入默认配置：App 控制模式绑定(层2)/多agent跳转 进 global，媒体/会议进 per-app overlay。
    // 不覆盖上面已设的槽位（apply 默认 force=false）。
    for p in Presets.all { Presets.apply(p, to: &cfg) }
    return cfg
}

// MARK: - 电平计（GUI 语音页实时电平表的数据源）

final class LevelMeterSink: PCMSink, @unchecked Sendable {
    /// 每批样本的 RMS（0…1），在 ATVV 队列上回调，消费方自行切主线程。
    var onLevel: ((Float) -> Void)?

    func streamStarted(sampleRate: Double) { onLevel?(0) }
    func write(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var acc = 0.0
        for s in samples { let d = Double(s); acc += d * d }
        let rms = (acc / Double(samples.count)).squareRoot() / 32768.0
        onLevel?(Float(min(1, rms)))
    }
    func streamStopped() { onLevel?(0) }
}

// MARK: - 语音链路（M1）

final class VoiceBridgeApp: ATVVBridgeDelegate {
    private let decoder = ADPCMDecoder()
    private let post: PCMPostprocessor
    private let sink: PCMSink
    private let verbose: Bool
    /// GUI 语音页可切换（模式 A=true / 模式 B=false）。ATVV 队列读、主线程写，布尔读写原子性可接受。
    var switchInput: Bool
    /// 是否触发豆包（模式 off=false）。
    var doubao: Bool

    /// GUI 状态反馈钩子（ATVV 队列回调）。
    var onConnection: ((Bool, String?) -> Void)?
    var onVoiceActive: ((Bool) -> Void)?
    /// GUI 注入：在一次语音会话开始时，按最近的前台 App 解析快捷键。
    var resolveTriggerConfig: (() -> VoiceTriggerConfig)?

    /// 语音会话期间默认麦克风的切换目标（前缀匹配；默认 BlackHole，配置可换）。
    private let micDeviceName: String

    init(outputName: String?, wavPath: String?, gainDB: Double, verbose: Bool,
         switchInput: Bool, doubao: Bool, micDeviceName: String = "BlackHole",
         extraSink: PCMSink? = nil) {
        self.post = PCMPostprocessor(gainDB: gainDB)
        self.verbose = verbose
        self.switchInput = switchInput
        self.doubao = doubao
        self.micDeviceName = micDeviceName
        var sinks: [PCMSink] = [AudioBridge(deviceName: outputName)]
        if let wavPath {
            sinks.append(WAVSink(url: URL(fileURLWithPath: wavPath)))
        }
        if let extraSink { sinks.append(extraSink) }
        self.sink = sinks.count == 1 ? sinks[0] : TeeSink(sinks)
    }

    func atvvLog(_ message: String) {
        if verbose { log(message) }
    }

    func atvvConnected(deviceName: String) {
        log("已连接: \(deviceName)")
        print("READY")
        onConnection?(true, deviceName)
    }

    func atvvDisconnected(error: String?) {
        log("断开连接\(error.map { ": \($0)" } ?? "")（自动重连中）")
        onConnection?(false, nil)
    }

    func atvvVoiceStarted() {
        log("语音开始")
        onVoiceActive?(true)
        restoreWork?.cancel()
        restoreWork = nil
        if switchInput {
            log(DefaultInput.engage(deviceName: micDeviceName)
                ? "默认麦克风 → \(micDeviceName)"
                : "切换默认麦克风失败（未找到 \(micDeviceName)*，未装虚拟声卡？语音出字不可用，按键功能不受影响）")
        }
        // 抖动幽灵会话（有 START/STOP 但零音频帧）不触发语音工具：
        // 等第一个音频帧到达再触发，幽灵会话就永远碰不到豆包。
        pendingTrigger = doubao
        triggered = false
        decoder.reset(predictor: 0, stepIndex: 0)
        post.reset()
        sink.streamStarted(sampleRate: 16000)
    }

    private var restoreWork: DispatchWorkItem?
    private var pendingTrigger = false
    private var triggered = false

    func atvvVoiceStopped() {
        log("语音结束")
        onVoiceActive?(false)
        pendingTrigger = false
        if doubao && triggered { VoiceTrigger.end() } // 只有真正触发过才停
        if switchInput {
            // 延迟还原麦克风：给识别收尾留 1.2s，期间听到的是 BlackHole 静音而非环境音
            let work = DispatchWorkItem {
                DefaultInput.restore()
                log("默认麦克风已还原")
            }
            restoreWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2, execute: work)
        }
        sink.streamStopped()
    }

    func atvvAudioFrame(_ frame: Data, sync: (predictor: Int16, stepIndex: Int)?) {
        if pendingTrigger {
            pendingTrigger = false
            triggered = true
            VoiceTrigger.begin(config: resolveTriggerConfig?())
        }
        if let sync {
            decoder.reset(predictor: sync.predictor, stepIndex: sync.stepIndex)
        }
        sink.write(post.process(decoder.decode(frame)))
    }
}

// MARK: - M2 按键映射接线

final class KeyMapperApp: HIDEngineDelegate, MappingEngineDelegate {
    let runner = ActionRunner()
    var engine: MappingEngine!
    let verbose: Bool

    /// GUI 状态反馈钩子。
    var onLayerChanged: ((Int) -> Void)?
    var onSeizeState: ((Bool) -> Void)?
    /// 引擎路径上的每个按键事件（GUI「按下即亮」）。回调线程=事件来源线程。
    var onButtonEvent: ((ButtonEvent) -> Void)?
    var onActiveApplication: ((String?) -> Void)?

    /// 最近一个「非本进程」的前台应用（防止本 App 自己的设置窗口污染 per-app profile）。
    private(set) var lastExternalApplication: NSRunningApplication?

    /// 外部 App 的 MRU 栈（最新在前，最多 3 个；[0]=当前前台，[1]=上一个）。
    /// 主线程维护（NSWorkspace 通知在主线程投递）；App 轮盘 UI 直接读，
    /// `app_mru_back` 动作经主线程走 activateMRUBack()。
    private(set) var mruExternalApplications: [NSRunningApplication] = []
    private static let mruCapacity = 5   // App 轮盘容量（五大 App 目标，DESIGN §3.1b）

    /// MRU 压栈纯逻辑（自测覆盖）：去重后插到栈顶，截断到 cap。
    static func mruPush(_ stack: [String], _ id: String, cap: Int = mruCapacity) -> [String] {
        var next = stack.filter { $0 != id }
        next.insert(id, at: 0)
        if next.count > cap { next.removeLast(next.count - cap) }
        return next
    }

    /// MRU 回切目标纯逻辑（自测覆盖）：栈顶是当前前台，目标 = 第一个非当前项。
    static func mruBackTarget(_ stack: [String], current: String?) -> String? {
        stack.first { $0 != current }
    }

    private func pushMRU(_ app: NSRunningApplication) {
        mruExternalApplications.removeAll {
            $0.processIdentifier == app.processIdentifier || $0.isTerminated
        }
        mruExternalApplications.insert(app, at: 0)
        if mruExternalApplications.count > Self.mruCapacity {
            mruExternalApplications.removeLast(mruExternalApplications.count - Self.mruCapacity)
        }
    }

    /// `app_mru_back`：切到上一个外部 App（栈里第一个非当前前台且仍存活的）。主线程调用。
    func activateMRUBack() {
        let currentPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let target = mruExternalApplications.first(where: {
            !$0.isTerminated && $0.processIdentifier != currentPid
        }) else {
            log("app_mru_back：无可回切的上一个 App")
            return
        }
        target.activate()
    }

    init(config: MappingConfig, verbose: Bool) {
        self.verbose = verbose
        engine = MappingEngine(config: config, runner: runner, delegate: self)
        // 启动时用当前前台 app seed（忽略自己）。
        let myPid = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPid {
            lastExternalApplication = front
            pushMRU(front)
            engine.setActiveProfile(front.bundleIdentifier)
            onActiveApplication?(front.bundleIdentifier)
        }
        // 前台 app 变化 → 自动切 profile。忽略本进程（设置窗口拿到前台不改 profile）。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != myPid else { return }
            self.lastExternalApplication = app
            self.pushMRU(app)
            self.engine.setActiveProfile(app.bundleIdentifier)
            self.onActiveApplication?(app.bundleIdentifier)
        }
    }

    func hidLog(_ message: String) { if verbose { log("HID \(message)") } }
    func hidButton(_ event: ButtonEvent) {
        if verbose { log("KEY \(event.key.rawValue) \(event.isDown ? "↓" : "↑")") }
        onButtonEvent?(event)
        // M5 v2：Home 长按教程浮层改走引擎的 hold=.overlay("tutorial") 常规路径，
        // 浮层打开后由 uiCapture 捕获后续按键（含再按 Home 关闭）。
        engine.handle(event)
    }

    func hidSeizeState(_ exclusive: Bool) {
        log(exclusive ? "按键已独占接管" : "按键降级为监听模式（系统仍会响应原始按键）")
        onSeizeState?(exclusive)
    }
    func mappingLog(_ message: String) { if verbose { log("MAP \(message)") } }
    func layerChanged(_ layer: Int) {
        log("层 → \(layer)")
        onLayerChanged?(layer)
    }
}

/// 主线程写配置/前台 App，蓝牙队列读；用锁隔离跨线程状态。
private final class VoiceRuleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [String: VoiceTriggerRule]?
    private var bundleID: String?

    func update(config: MappingConfig) {
        lock.lock(); rules = config.voiceProfiles; lock.unlock()
    }

    func update(bundleID: String?) {
        lock.lock(); self.bundleID = bundleID; lock.unlock()
    }

    func resolve() -> VoiceTriggerConfig {
        lock.lock()
        let snapshotRules = rules
        let snapshotBundle = bundleID
        lock.unlock()
        return VoiceTriggerRouting.resolve(snapshotRules, bundleID: snapshotBundle)
    }
}

/// IOHID 监听通道的过滤器：只放行"系统天然忽略"的键（如 back 0xF1），
/// 其余键由 hidutil 中转 + CGEventTap 处理，这里放行会造成双触发。
final class IOHIDOnlyFilter: HIDEngineDelegate {
    let target: KeyMapperApp
    let allowed: Set<RemoteKey> = [.back]
    /// 所有原始按键事件（含被过滤不进引擎的），GUI「识别按键」学习模式用。
    var onRawButton: ((ButtonEvent) -> Void)?
    init(_ target: KeyMapperApp) { self.target = target }
    func hidLog(_ message: String) { target.hidLog(message) }
    func hidButton(_ event: ButtonEvent) {
        target.hidLog("IOHID读到 \(event.key.rawValue) \(event.isDown ? "↓" : "↑")")
        onRawButton?(event)
        if allowed.contains(event.key) { target.hidButton(event) }
    }
    func hidSeizeState(_ exclusive: Bool) {} // 监听模式，无独占概念
}

// MARK: - 服务容器（CLI/GUI 共用的接线）

/// 一次性组装语音链路 + 按键映射链路，start/stop 生命周期成对。
/// GUI 与 CLI 共用；差异只在 Options 与事件钩子。
final class AppServices {

    struct Options {
        var outputName: String? = "BlackHole 2ch"
        /// CLI --output 显式给过（显式值优先于 config settings.voiceOutputDevice）。
        var outputExplicit = false
        /// CLI --trigger-key/--trigger-mode/--ime 的覆盖记录（nil=未给 → 用配置或内置默认）。
        var cliTriggerKey: String?
        var cliTriggerMode: String?
        var cliIMEGiven = false
        var cliIME: String?
        var wavPath: String?
        var gainDB: Double = 0
        var verbose = false
        var switchInput = true
        var doubao = false
        var keys = false
        /// GUI 开启；CLI 保留 --trigger-key/--trigger-mode/--ime 的全局覆盖行为。
        var perAppVoiceRouting = false
        var configPath: String?
        /// GUI 附加：电平表 sink
        var levelSink: PCMSink?
    }

    let options: Options
    let voiceApp: VoiceBridgeApp
    let bridge: ATVVBridge
    let health = HealthMonitor()
    /// 等待批准提醒：本地 socket 收 Claude Code hook 事件（GUI/CLI 服务模式都监听）。
    let eventListener = EventListener()
    private(set) var keyMapper: KeyMapperApp?
    private(set) var tapEngine: TapEngine?
    private(set) var hidFilter: IOHIDOnlyFilter?
    private(set) var hidEngine: HIDEngine?
    private(set) var started = false
    private let voiceRuleStore = VoiceRuleStore()

    /// 启动期语音触发三级合并（纯函数，供自测）：内置默认 ← 配置 global 规则 ← CLI 标志。
    /// cliIME 双层 Optional：nil=CLI 未给；.some(nil)=--ime none（不切输入法）；.some(v)=指定前缀。
    static func startupVoiceTriggerConfig(globalRule: VoiceTriggerRule?,
                                          cliKey: String?, cliMode: String?,
                                          cliIME: String??) -> VoiceTriggerConfig {
        var cfg = VoiceTriggerRouting.resolve(globalRule.map { ["global": $0] }, bundleID: nil)
        if let cliKey, VoiceTriggerConfig.keyTable[cliKey] != nil { cfg.keyName = cliKey }
        if let cliMode, let mode = VoiceTriggerConfig.Mode(rawValue: cliMode) { cfg.mode = mode }
        if let cliIME { cfg.imeBundlePrefix = cliIME }
        return cfg
    }

    init(options: Options) {
        // 启动早期只读预载配置：settings 覆盖项（VID/PID、声卡名、终端白名单）
        // 与 voiceProfiles.global 需要在各引擎构建前生效。文件缺失/坏损 → 全部内置默认。
        let preloaded = ConfigStore.loadIfExists(at: options.configPath)
        let settings = preloaded?.settings ?? MappingConfig.Settings()
        RemoteIdentity.configure(vendorID: settings.remoteVendorID,
                                 productID: settings.remoteProductID)
        FocusInput.extraTerminalBundles = Set(settings.terminalApps ?? [])
        var options = options
        if !options.outputExplicit, let dev = settings.voiceOutputDevice {
            options.outputName = dev
        }
        VoiceTrigger.config = Self.startupVoiceTriggerConfig(
            globalRule: preloaded?.voiceProfiles?["global"],
            cliKey: options.cliTriggerKey,
            cliMode: options.cliTriggerMode,
            cliIME: options.cliIMEGiven ? .some(options.cliIME) : nil)
        self.options = options
        voiceApp = VoiceBridgeApp(outputName: options.outputName,
                                  wavPath: options.wavPath,
                                  gainDB: options.gainDB,
                                  verbose: options.verbose,
                                  switchInput: options.switchInput,
                                  doubao: options.doubao,
                                  micDeviceName: settings.voiceOutputDevice ?? "BlackHole",
                                  extraSink: options.levelSink)
        bridge = ATVVBridge(delegate: voiceApp)
        health.log = { log("健康 \($0)") }
        voiceApp.onConnection = { [weak health] connected, _ in
            health?.setBLEConnected(connected)
        }
    }

    /// 启动全部服务（幂等）。keys 链路仅在 options.keys 时启动。
    func start() {
        guard !started else { return }
        started = true
        KeyRemapper.log = { log("HIDUTIL \($0)") }
        switch KeyRemapper.cleanResidualMapping() {
        case .cleaned(let count):
            log("检测到上次异常退出残留（\(count) 条 hidutil 中转映射），已清理")
        case .cleanFailed:
            log("检测到上次异常退出残留，但清理失败（可运行 --doctor 重试）")
        case .none, .queryFailed:
            break
        }
        if options.keys {
            let config = loadOrCreateConfig(at: options.configPath)
            voiceRuleStore.update(config: config)
            let km = KeyMapperApp(config: config, verbose: options.verbose)
            voiceRuleStore.update(bundleID: km.lastExternalApplication?.bundleIdentifier)
            km.onActiveApplication = { [weak voiceRuleStore] bundleID in
                voiceRuleStore?.update(bundleID: bundleID)
            }
            if options.perAppVoiceRouting {
                voiceApp.resolveTriggerConfig = { [weak voiceRuleStore] in
                    voiceRuleStore?.resolve() ?? VoiceTriggerConfig()
                }
            }
            // app_mru_back 动作出口：切到 MRU 栈里的上一个外部 App（P6 核心侧）。
            ActionRunner.onAppMRUBack = { [weak km] in km?.activateMRUBack() }
            let tap = TapEngine(delegate: km)
            tap.router = km.engine  // 方向键三态分流的快照来源
            let filter = IOHIDOnlyFilter(km)
            let hid = HIDEngine(delegate: filter)
            keyMapper = km
            tapEngine = tap
            hidFilter = filter
            hidEngine = hid
            health.setKeysEnabled(true)
            km.onSeizeState = { [weak health] alive in health?.setTapAlive(alive) }
            health.reinstallMapping = { [weak tap] in
                tap?.reinstallMapping(reason: "周期健康检查发现映射缺失")
            }
            // 映射生命周期：蓝牙重连后设备服务重建，hidutil 映射可能失效 → 幂等重装；
            // 设备移除 / 系统睡眠可能丢 keyUp → 复位引擎与 tap 的按压状态。
            hid.onDeviceMatched = { tap.reinstallMapping(reason: "设备重连") }
            hid.onDeviceRemoved = {
                km.engine.resetInputState(reason: "设备移除")
                tap.resetPressState()
            }
            let wsnc = NSWorkspace.shared.notificationCenter
            wsnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                tap.reinstallMapping(reason: "系统唤醒")
            }
            wsnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                km.engine.resetInputState(reason: "系统睡眠")
                tap.resetPressState()
            }
            tap.start()
            hid.start()
            log("按键映射已启用（hidutil 中转 + CGEventTap + IOHID 监听兜底）")
        }
        eventListener.log = { log("EVENT \($0)") }
        eventListener.onEvent = { event in
            AgentNotifier.notify(event) { log("EVENT \($0)") }
        }
        eventListener.start()
        health.startPeriodicChecks()
        log("启动，输出设备: \(options.outputName ?? "系统默认")\(options.wavPath.map { "，WAV: \($0)" } ?? "")")
        bridge.start()
    }

    /// 停止并恢复系统状态（hidutil 中转恢复、语音断开）。幂等。
    func stop() {
        guard started else { return }
        started = false
        eventListener.stop()
        health.stop()
        bridge.stop()
        tapEngine?.stop() // 恢复 hidutil 映射
        hidEngine?.stop()
        log("服务已停止，hidutil 中转已恢复")
    }

    /// 热加载映射配置（UI 写回 config.json 后调用）。
    /// settings 里的 VID/PID、声卡名改动需重启进程生效（引擎构建期绑定）；终端白名单即刻生效。
    func applyConfig(_ config: MappingConfig) {
        FocusInput.extraTerminalBundles = Set(config.settings.terminalApps ?? [])
        voiceRuleStore.update(config: config)
        keyMapper?.engine.setConfig(config)
    }

    /// 体检「重建通道」：重装 hidutil 映射（TapEngine 内部含 tap 健康自愈）。
    func reinstallMapping() {
        tapEngine?.reinstallMapping(reason: "体检修复")
    }

    func runRepair() -> RepairReport {
        HealthMonitor.runRepair(runtime: health.sourcesSnapshot) { [weak self] in
            self?.reinstallMapping()
        }
    }
}
