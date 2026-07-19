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
        if let cfg = ConfigStore.load(from: url) {
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

func defaultConfig() -> MappingConfig {
    // 默认配置：方向=方向键（层1 示例：上下=音量），OK=回车/长按进层1/按住+方向=手势，
    // 返回=退格，菜单=调度中心，主页=启动台，TV=打开系统设置，电源=熄屏，音量=系统音量。
    // 语音键放行给 ATVV。
    var cfg = MappingConfig()
    cfg.profiles["global"] = [
        "up":      KeyBinding(tap: .keyStroke(key: "up_arrow", mods: []),
                              layers: ["1": .system("volume_up")]),
        "down":    KeyBinding(tap: .keyStroke(key: "down_arrow", mods: []),
                              layers: ["1": .system("volume_down")]),
        "left":    KeyBinding(tap: .keyStroke(key: "left_arrow", mods: [])),
        "right":   KeyBinding(tap: .keyStroke(key: "right_arrow", mods: [])),
        "ok":      KeyBinding(tap: .keyStroke(key: "return", mods: []),
                              hold: .layerMomentary(1),
                              gesture: [
                                  "up":    .system("mission_control"),
                                  "down":  .windowCycle(scope: "app"),
                                  "left":  .keyStroke(key: "left_bracket", mods: ["left_cmd", "left_shift"]),
                                  "right": .keyStroke(key: "right_bracket", mods: ["left_cmd", "left_shift"]),
                              ]),
        "back":    KeyBinding(tap: .keyStroke(key: "delete", mods: [])),
        "menu":    KeyBinding(tap: .system("mission_control")),
        "home":    KeyBinding(tap: .system("launchpad")),
        // TV 双击 = 进/出 AI 批准层（层2，见 Presets.aiApprovalLayer）
        "tv":      KeyBinding(tap: .openApp("com.apple.systempreferences"),
                              double: .layerToggle(2)),
        "power":   KeyBinding(tap: .system("display_sleep")),
        "volUp":   KeyBinding(tap: .system("volume_up")),
        "volDown": KeyBinding(tap: .system("volume_down")),
        "voice":   KeyBinding(tap: .voice),
    ]
    // 内置预设并入默认配置：AI 批准层(层2)/多agent跳转 进 global，媒体/会议进 per-app overlay。
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

    init(outputName: String?, wavPath: String?, gainDB: Double, verbose: Bool,
         switchInput: Bool, doubao: Bool, extraSink: PCMSink? = nil) {
        self.post = PCMPostprocessor(gainDB: gainDB)
        self.verbose = verbose
        self.switchInput = switchInput
        self.doubao = doubao
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
            log(DefaultInput.engage(deviceName: "BlackHole") ? "默认麦克风 → BlackHole" : "切换默认麦克风失败")
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
            VoiceTrigger.begin()
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

    /// 最近一个「非本进程」的前台应用（防止本 App 自己的设置窗口污染 per-app profile）。
    private(set) var lastExternalApplication: NSRunningApplication?

    init(config: MappingConfig, verbose: Bool) {
        self.verbose = verbose
        engine = MappingEngine(config: config, runner: runner, delegate: self)
        // 启动时用当前前台 app seed（忽略自己）。
        let myPid = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPid {
            lastExternalApplication = front
            engine.setActiveProfile(front.bundleIdentifier)
        }
        // 前台 app 变化 → 自动切 profile。忽略本进程（设置窗口拿到前台不改 profile）。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != myPid else { return }
            self.lastExternalApplication = app
            self.engine.setActiveProfile(app.bundleIdentifier)
        }
    }

    func hidLog(_ message: String) { if verbose { log("HID \(message)") } }
    func hidButton(_ event: ButtonEvent) {
        if verbose { log("KEY \(event.key.rawValue) \(event.isDown ? "↓" : "↑")") }
        onButtonEvent?(event)
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
        var wavPath: String?
        var gainDB: Double = 0
        var verbose = false
        var switchInput = true
        var doubao = false
        var keys = false
        var configPath: String?
        /// GUI 附加：电平表 sink
        var levelSink: PCMSink?
    }

    let options: Options
    let voiceApp: VoiceBridgeApp
    let bridge: ATVVBridge
    let health = HealthMonitor()
    private(set) var keyMapper: KeyMapperApp?
    private(set) var tapEngine: TapEngine?
    private(set) var hidFilter: IOHIDOnlyFilter?
    private(set) var hidEngine: HIDEngine?
    private(set) var started = false

    init(options: Options) {
        self.options = options
        voiceApp = VoiceBridgeApp(outputName: options.outputName,
                                  wavPath: options.wavPath,
                                  gainDB: options.gainDB,
                                  verbose: options.verbose,
                                  switchInput: options.switchInput,
                                  doubao: options.doubao,
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
            let km = KeyMapperApp(config: loadOrCreateConfig(at: options.configPath), verbose: options.verbose)
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
        health.startPeriodicChecks()
        log("启动，输出设备: \(options.outputName ?? "系统默认")\(options.wavPath.map { "，WAV: \($0)" } ?? "")")
        bridge.start()
    }

    /// 停止并恢复系统状态（hidutil 中转恢复、语音断开）。幂等。
    func stop() {
        guard started else { return }
        started = false
        health.stop()
        bridge.stop()
        tapEngine?.stop() // 恢复 hidutil 映射
        hidEngine?.stop()
        log("服务已停止，hidutil 中转已恢复")
    }

    /// 热加载映射配置（UI 写回 config.json 后调用）。
    func applyConfig(_ config: MappingConfig) {
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
