import Foundation

// 模块间契约。并行开发的各模块严格遵守此文件签名，不得改动。

/// 遥控器 USB 识别信息（可在 config.json settings 里覆盖，换其他型号遥控器用）。
/// 默认 = 小米蓝牙遥控器 2 Pro。启动早期由 AppServices 按配置 configure 一次，
/// 之后 HIDEngine / KeyRemapper / EnvironmentCheck 只读——无并发写。
enum RemoteIdentity {
    static let defaultVendorID  = 0x2717
    static let defaultProductID = 0x32B8

    nonisolated(unsafe) private(set) static var vendorID  = defaultVendorID
    nonisolated(unsafe) private(set) static var productID = defaultProductID

    static func configure(vendorID: Int?, productID: Int?) {
        self.vendorID  = vendorID  ?? defaultVendorID
        self.productID = productID ?? defaultProductID
    }

    /// hidutil --matching 串（纯函数，供自测）。与 VID/PID 始终同步生成。
    static func hidutilMatching(vendorID: Int, productID: Int) -> String {
        "{\"VendorID\":\(String(format: "0x%X", vendorID)),\"ProductID\":\(String(format: "0x%X", productID))}"
    }
    static var hidutilMatching: String {
        hidutilMatching(vendorID: vendorID, productID: productID)
    }
}

enum ATVVUUID {
    static let service = "AB5E0001-5A21-4F05-BC7D-AF01F617B664"
    static let tx      = "AB5E0002-5A21-4F05-BC7D-AF01F617B664" // 主机写命令
    static let audio   = "AB5E0003-5A21-4F05-BC7D-AF01F617B664" // 音频帧 notify
    static let control = "AB5E0004-5A21-4F05-BC7D-AF01F617B664" // 控制 notify
}

/// PCM 消费端（AudioBridge 实现；WAV 调试输出也实现它）
protocol PCMSink: AnyObject {
    /// 语音流开始（sampleRate 如 16000）
    func streamStarted(sampleRate: Double)
    /// 一批解码后的 16-bit 单声道样本
    func write(_ samples: [Int16])
    /// 语音流结束
    func streamStopped()
}

// MARK: - M2 按键映射契约

/// 遥控器 13 个实体键（usage 均在键盘页 0x07，2026-07-19 实机探针确认）
enum RemoteKey: String, CaseIterable, Codable {
    case power, voice, up, down, left, right, ok, back, home, menu, tv, volUp, volDown

    static let usageMap: [UInt32: RemoteKey] = [
        0x66: .power, 0x3E: .voice,
        0x52: .up, 0x51: .down, 0x50: .left, 0x4F: .right, 0x28: .ok,
        0xF1: .back, 0x4A: .home, 0x65: .menu, 0x35: .tv,
        0x80: .volUp, 0x81: .volDown,
    ]
}

/// 原始按键事件（HIDEngine 产出）
struct ButtonEvent {
    let key: RemoteKey
    let isDown: Bool
    let timeNs: UInt64   // DispatchTime.now().uptimeNanoseconds
}

protocol HIDEngineDelegate: AnyObject {
    func hidLog(_ message: String)
    func hidButton(_ event: ButtonEvent)
    /// true=独占(seize)成功；false=降级为监听模式
    func hidSeizeState(_ exclusive: Bool)
}

/// 动作（配置 JSON 的 Codable 模型）。type 字段区分。
enum Action: Codable, Equatable {
    case keyStroke(key: String, mods: [String])   // key=键名(如"return","right_arrow","k")
    case system(String)                           // volume_up/volume_down/mute/play_pause/mission_control/launchpad/display_sleep/lock_screen
    case openApp(String)                          // bundle id
    case shell(String)                            // 命令行
    case voice                                    // 语音键行为（ATVV 侧处理，映射层放行）
    case layerMomentary(Int)
    case layerToggle(Int)
    // M4 高级动作
    case windowCycle(scope: String)               // "app"=同应用窗口循环（默认）/ "global"=全局 MRU 循环
    case tabJump(dir: Int?, index: Int?)          // dir=±1 相对切标签(cmd+shift+[/]) / index=N 直跳(cmd+数字)
    case focusInput                               // 自动聚焦前台 app 输入框（三级兜底）
    case mouseMode                                // toggle 进入/退出鼠标模式
    case macro(steps: [MacroStep])                // 多步序列
    // M5 v2 心智模型：打开一个 GUI 浮层（window_picker / system_menu / tutorial）。
    // CLI 模式无 GUI，执行时仅记日志。名字用 String 保持向前兼容（新增浮层不改契约）。
    case overlay(String)
    case none

    private enum K: String, CodingKey { case type, key, mods, value, scope, dir, index, steps }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "key_stroke": self = .keyStroke(key: try c.decode(String.self, forKey: .key),
                                             mods: try c.decodeIfPresent([String].self, forKey: .mods) ?? [])
        case "system":     self = .system(try c.decode(String.self, forKey: .value))
        case "open_app":   self = .openApp(try c.decode(String.self, forKey: .value))
        case "shell":      self = .shell(try c.decode(String.self, forKey: .value))
        case "voice":      self = .voice
        case "layer_momentary": self = .layerMomentary(try c.decode(Int.self, forKey: .value))
        case "layer_toggle":    self = .layerToggle(try c.decode(Int.self, forKey: .value))
        case "window_cycle": self = .windowCycle(scope: try c.decodeIfPresent(String.self, forKey: .scope) ?? "app")
        case "tab_jump":     self = .tabJump(dir: try c.decodeIfPresent(Int.self, forKey: .dir),
                                             index: try c.decodeIfPresent(Int.self, forKey: .index))
        case "focus_input":  self = .focusInput
        case "mouse_mode":   self = .mouseMode
        case "macro":        self = .macro(steps: try c.decodeIfPresent([MacroStep].self, forKey: .steps) ?? [])
        case "overlay":      self = .overlay(try c.decode(String.self, forKey: .value))
        case "none":         self = .none
        case let other:
            // 严格解码：未知 type 抛错而非静默降级为 .none，拼写错误在加载配置时即暴露
            //（main 的配置加载 catch 后回退默认配置并记日志）。
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "未知动作 type: \(other)")
        }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case .keyStroke(let k, let m): try c.encode("key_stroke", forKey: .type); try c.encode(k, forKey: .key); try c.encode(m, forKey: .mods)
        case .system(let v):    try c.encode("system", forKey: .type); try c.encode(v, forKey: .value)
        case .openApp(let v):   try c.encode("open_app", forKey: .type); try c.encode(v, forKey: .value)
        case .shell(let v):     try c.encode("shell", forKey: .type); try c.encode(v, forKey: .value)
        case .voice:            try c.encode("voice", forKey: .type)
        case .layerMomentary(let v): try c.encode("layer_momentary", forKey: .type); try c.encode(v, forKey: .value)
        case .layerToggle(let v):    try c.encode("layer_toggle", forKey: .type); try c.encode(v, forKey: .value)
        case .windowCycle(let scope): try c.encode("window_cycle", forKey: .type); try c.encode(scope, forKey: .scope)
        case .tabJump(let dir, let index):
            try c.encode("tab_jump", forKey: .type)
            try c.encodeIfPresent(dir, forKey: .dir)
            try c.encodeIfPresent(index, forKey: .index)
        case .focusInput:       try c.encode("focus_input", forKey: .type)
        case .mouseMode:        try c.encode("mouse_mode", forKey: .type)
        case .macro(let steps): try c.encode("macro", forKey: .type); try c.encode(steps, forKey: .steps)
        case .overlay(let v):   try c.encode("overlay", forKey: .type); try c.encode(v, forKey: .value)
        case .none:             try c.encode("none", forKey: .type)
        }
    }
}

/// 宏步骤：任意动作 / 延时 / 文本输入。JSON 里 delay/text 用专属 type，其余按 Action 解析。
///   {"type":"delay","ms":100}  {"type":"text","value":"hello"}  {"type":"key_stroke","key":"return"}
enum MacroStep: Codable, Equatable {
    case action(Action)
    case delay(ms: Int)
    case text(String)

    /// 单步延时上限（配置来源任意，负数/超大值不能进执行层：
    /// useconds_t 负数转换或乘法溢出会 trap，一个坏配置就能崩掉整个进程）。
    static let maxDelayMs = 60_000

    private enum K: String, CodingKey { case type, ms, value }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "delay":
            let ms = try c.decode(Int.self, forKey: .ms)
            guard ms >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ms, in: c, debugDescription: "delay 不能为负: \(ms)")
            }
            self = .delay(ms: min(ms, Self.maxDelayMs))
        case "text":  self = .text(try c.decode(String.self, forKey: .value))
        default:      self = .action(try Action(from: d))
        }
    }
    func encode(to e: Encoder) throws {
        switch self {
        case .action(let a): try a.encode(to: e)
        case .delay(let ms):
            var c = e.container(keyedBy: K.self)
            try c.encode("delay", forKey: .type); try c.encode(ms, forKey: .ms)
        case .text(let s):
            var c = e.container(keyedBy: K.self)
            try c.encode("text", forKey: .type); try c.encode(s, forKey: .value)
        }
    }
}

/// 单键绑定：五个动作位（均可省略）
struct KeyBinding: Codable {
    var tap: Action?
    var hold: Action?
    var double: Action?
    var gesture: [String: Action]?    // "up"/"down"/"left"/"right"（仅 OK 键生效）
    var layers: [String: Action]?     // "1" → 层1 激活时的 tap 替代
}

/// 遥控器开始传音频时，要向当前 App 发送的语音工具快捷键。
/// App 未单独配置时继承 `voiceProfiles["global"]`。
struct VoiceTriggerRule: Codable, Equatable {
    var keyName: String = "right_option"
    var mode: String = "hold"
    /// nil 表示独立语音 App（不切输入法）；豆包输入法使用其 bundle id 前缀。
    var imeBundlePrefix: String? = "com.bytedance.inputmethod"
}

struct MappingConfig: Codable {
    static let currentVersion = 5   // v5 = Home 双击调度中心 + 菜单键退出调度中心
    struct Settings: Codable {
        var holdMs: Int = 350
        /// 双击判定窗口。默认配置存在双击绑定（如 Zoom 预设 TV 双击=摄像头），故必须 >0；
        /// 引擎只对「配了 double 的键」引入此延迟，其余键 tap 仍零延迟（P7 收敛：定 250）。
        var doubleMs: Int = 250
        /// 基础文字输入态下，长按返回/删除是否执行“全选并删除”。nil 与 false 等价，
        /// 使用 Optional 以兼容旧版 config.json 的自动解码。
        var deleteAllOnHold: Bool? = nil
        // —— 以下均为可选覆盖项（nil = 内置默认），旧配置无这些字段照常解码 ——
        /// 遥控器 USB Vendor ID（nil = 0x2717 小米）。换其他遥控器型号时改。
        var remoteVendorID: Int? = nil
        /// 遥控器 USB Product ID（nil = 0x32B8 小米蓝牙遥控器 2 Pro）。
        var remoteProductID: Int? = nil
        /// 语音输出虚拟声卡名（前缀匹配；nil = "BlackHole 2ch"）。
        /// 同时用于语音会话期间的默认麦克风切换目标。
        var voiceOutputDevice: String? = nil
        /// 追加的终端类 App bundle id（focus_input 一级兜底白名单，与内置列表合并）。
        var terminalApps: [String]? = nil
    }
    var version: Int = currentVersion
    var settings: Settings = Settings()
    /// profile 名 → (键名 → 绑定)；"global" 必在，其余为 bundle id 覆盖层
    var profiles: [String: [String: KeyBinding]] = [:]
    /// profile 名 → 语音触发规则；缺少某 App 时继承 global。Optional 保证 v1/v2 可直接解码。
    var voiceProfiles: [String: VoiceTriggerRule]? = nil
}

/// 动作执行器（ActionRunner 实现；MappingEngine 调用）
protocol ActionRunning: AnyObject {
    func run(_ action: Action)
}

/// 映射引擎对外事件
protocol MappingEngineDelegate: AnyObject {
    func mappingLog(_ message: String)
    /// 层状态变化（0=基础层），用于状态反馈
    func layerChanged(_ layer: Int)
}

/// ATVV 桥事件（ATVVBridge 通过它上报；main 实现）
protocol ATVVBridgeDelegate: AnyObject {
    func atvvLog(_ message: String)                    // 状态/调试日志
    func atvvConnected(deviceName: String)
    func atvvDisconnected(error: String?)
    func atvvVoiceStarted()                            // 收到 0x04 流开始
    func atvvVoiceStopped()                            // 收到 0x00 流结束
    /// 一帧完整 ADPCM 数据（已按帧长切好，未解码）；sync 非 nil 表示先用它重置解码器
    func atvvAudioFrame(_ frame: Data, sync: (predictor: Int16, stepIndex: Int)?)
}
