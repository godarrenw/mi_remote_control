import Foundation
import AppKit

// M1 CLI：遥控器语音 → ATVV → ADPCM 解码 → BlackHole/WAV
// 用法: miremote [--list-audio-devices] [--output <设备名>] [--wav <路径>] [--gain <dB>] [--verbose]

func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

var outputName: String? = "BlackHole 2ch"
var wavPath: String?
var gainDB: Double = 0
var verbose = false
var switchInputFlag = true
var doubaoFlag = false
var keysFlag = false
var configPath: String?

var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--list-audio-devices":
        AudioBridge.listOutputDevices().forEach { print($0) }
        exit(0)
    case "--self-test":
        exit(SelfTest.run())
    case "--output":  outputName = args.isEmpty ? nil : args.removeFirst()
    case "--wav":     wavPath = args.isEmpty ? nil : args.removeFirst()
    case "--gain":    gainDB = Double(args.isEmpty ? "0" : args.removeFirst()) ?? 0
    case "--verbose": verbose = true
    case "--no-input-switch": switchInputFlag = false
    case "--doubao": doubaoFlag = true
    case "--keys": keysFlag = true
    case "--config":
        if !args.isEmpty { configPath = args.removeFirst() }
    case "--trigger-key":
        if !args.isEmpty { VoiceTrigger.config.keyName = args.removeFirst() }
    case "--trigger-mode":
        if !args.isEmpty, let m = VoiceTriggerConfig.Mode(rawValue: args.removeFirst()) { VoiceTrigger.config.mode = m }
    case "--ime":
        if !args.isEmpty {
            let v = args.removeFirst()
            VoiceTrigger.config.imeBundlePrefix = (v == "none") ? nil : v
        }
    case "--help", "-h":
        print("miremote [--list-audio-devices] [--output <name>] [--wav <path>] [--gain <dB>] [--verbose]")
        exit(0)
    default:
        FileHandle.standardError.write("未知参数: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

func log(_ msg: String) {
    FileHandle.standardError.write("[\(ts())] \(msg)\n".data(using: .utf8)!)
}

final class VoiceBridgeApp: ATVVBridgeDelegate {
    private let decoder = ADPCMDecoder()
    private let post: PCMPostprocessor
    private let sink: PCMSink
    private let verbose: Bool
    private let switchInput: Bool
    private let doubao: Bool

    init(outputName: String?, wavPath: String?, gainDB: Double, verbose: Bool, switchInput: Bool, doubao: Bool) {
        self.post = PCMPostprocessor(gainDB: gainDB)
        self.verbose = verbose
        self.switchInput = switchInput
        self.doubao = doubao
        var sinks: [PCMSink] = [AudioBridge(deviceName: outputName)]
        if let wavPath {
            sinks.append(WAVSink(url: URL(fileURLWithPath: wavPath)))
        }
        self.sink = sinks.count == 1 ? sinks[0] : TeeSink(sinks)
    }

    func atvvLog(_ message: String) {
        if verbose { log(message) }
    }

    func atvvConnected(deviceName: String) {
        log("已连接: \(deviceName)")
        print("READY")
    }

    func atvvDisconnected(error: String?) {
        log("断开连接\(error.map { ": \($0)" } ?? "")（自动重连中）")
    }

    func atvvVoiceStarted() {
        log("语音开始")
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

    init(config: MappingConfig, verbose: Bool) {
        self.verbose = verbose
        engine = MappingEngine(config: config, runner: runner, delegate: self)
        // 前台 app 变化 → 自动切 profile
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self?.engine.setActiveProfile(bundle)
        }
    }

    func hidLog(_ message: String) { if verbose { log("HID \(message)") } }
    func hidButton(_ event: ButtonEvent) {
        if verbose { log("KEY \(event.key.rawValue) \(event.isDown ? "↓" : "↑")") }
        engine.handle(event)
    }
    func hidSeizeState(_ exclusive: Bool) {
        log(exclusive ? "按键已独占接管" : "按键降级为监听模式（系统仍会响应原始按键）")
    }
    func mappingLog(_ message: String) { if verbose { log("MAP \(message)") } }
    func layerChanged(_ layer: Int) { log("层 → \(layer)") }
}

func loadOrCreateConfig() -> MappingConfig {
    let url: URL
    if let configPath {
        url = URL(fileURLWithPath: configPath)
    } else {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }
    if let data = try? Data(contentsOf: url), let cfg = try? JSONDecoder().decode(MappingConfig.self, from: data) {
        log("配置已加载: \(url.path)")
        return cfg
    }
    // 默认配置：方向=方向键，OK=回车，返回=退格，菜单=调度中心，主页=启动台，
    // TV=打开系统设置，电源=熄屏，音量=系统音量。语音键放行给 ATVV。
    var cfg = MappingConfig()
    cfg.profiles["global"] = [
        "up":      KeyBinding(tap: .keyStroke(key: "up_arrow", mods: [])),
        "down":    KeyBinding(tap: .keyStroke(key: "down_arrow", mods: [])),
        "left":    KeyBinding(tap: .keyStroke(key: "left_arrow", mods: [])),
        "right":   KeyBinding(tap: .keyStroke(key: "right_arrow", mods: [])),
        "ok":      KeyBinding(tap: .keyStroke(key: "return", mods: [])),
        "back":    KeyBinding(tap: .keyStroke(key: "delete", mods: [])),
        "menu":    KeyBinding(tap: .system("mission_control")),
        "home":    KeyBinding(tap: .system("launchpad")),
        "tv":      KeyBinding(tap: .openApp("com.apple.systempreferences")),
        "power":   KeyBinding(tap: .system("display_sleep")),
        "volUp":   KeyBinding(tap: .system("volume_up")),
        "volDown": KeyBinding(tap: .system("volume_down")),
        "voice":   KeyBinding(tap: .voice),
    ]
    if let data = try? JSONEncoder().encode(cfg) {
        try? data.write(to: url)
        log("已生成默认配置: \(url.path)")
    }
    return cfg
}

let app = VoiceBridgeApp(outputName: outputName, wavPath: wavPath, gainDB: gainDB, verbose: verbose, switchInput: switchInputFlag, doubao: doubaoFlag)
let bridge = ATVVBridge(delegate: app)

/// IOHID 监听通道的过滤器：只放行"系统天然忽略"的键（如 back 0xF1），
/// 其余键由 hidutil 中转 + CGEventTap 处理，这里放行会造成双触发。
final class IOHIDOnlyFilter: HIDEngineDelegate {
    let target: KeyMapperApp
    let allowed: Set<RemoteKey> = [.back]
    init(_ target: KeyMapperApp) { self.target = target }
    func hidLog(_ message: String) { target.hidLog(message) }
    func hidButton(_ event: ButtonEvent) {
        target.hidLog("IOHID读到 \(event.key.rawValue) \(event.isDown ? "↓" : "↑")")
        if allowed.contains(event.key) { target.hidButton(event) }
    }
    func hidSeizeState(_ exclusive: Bool) {} // 监听模式，无独占概念
}

var keyMapper: KeyMapperApp?
var tapEngine: TapEngine?
var hidFilter: IOHIDOnlyFilter?
var hidEngine: HIDEngine?
if keysFlag {
    let km = KeyMapperApp(config: loadOrCreateConfig(), verbose: verbose)
    let tap = TapEngine(delegate: km)
    let filter = IOHIDOnlyFilter(km)
    let hid = HIDEngine(delegate: filter)
    keyMapper = km
    tapEngine = tap
    hidFilter = filter
    hidEngine = hid
    tap.start()
    hid.start()
    log("按键映射已启用（hidutil 中转 + CGEventTap + IOHID 监听兜底）")
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    log("退出中…")
    bridge.stop()
    tapEngine?.stop() // 恢复 hidutil 映射
    exit(0)
}
sigint.resume()

log("启动，输出设备: \(outputName ?? "系统默认")\(wavPath.map { "，WAV: \($0)" } ?? "")")
bridge.start()
RunLoop.main.run()
