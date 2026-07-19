import Foundation
import CoreGraphics

/// M2 按键接管的最终架构（实机验证 2026-07-19）：
/// macOS 不允许用户态 seize 蓝牙 HID 键盘（0xE00002C1），IOHID 独占不可行。
/// 正路：hidutil 把有副作用的键在内核层重映射到 F13-F19（系统零默认行为），
/// 再用 CGEventTap 捕获并吞掉这些中转键，反查回原始键触发动作。
/// 音量键保持系统原生（默认行为即所需）。
/// M3：方向键也进中转表，TapEngine 按 MappingEngine 快照三态分流：
/// 纯原生场景就地改写回方向键 keycode 放行（保住系统 autorepeat 与零延迟），
/// 层/手势场景吞掉喂引擎。

enum KeyRemapper {

    /// (遥控器原始 usage, 中转键 usage, 中转键 macOS keycode, 逻辑键)
    static let table: [(src: UInt32, dst: UInt32, keycode: Int64, key: RemoteKey)] = [
        // back(0xF1) 不在此表：超出标准键盘 usage 范围，hidutil 不认、系统也忽略它，
        // 它由 IOHID 监听通道直接读取（无双触发风险，系统本来就不处理 0xF1）。
        (0x4A, 0x69, 107, .home),   // F14
        (0x65, 0x6A, 113, .menu),   // F15
        (0x35, 0x6B, 106, .tv),     // F16
        (0x66, 0x6C, 64,  .power),  // F17
        (0x28, 0x6D, 79,  .ok),     // F18
        // 方向键中转。F21-F24 在 macOS 没有虚拟键码（<HIToolbox/Events.h> 只到 kVK_F20，
        // 2026-07 对照本机 SDK 核实），映过去系统不产事件——不可用。
        // 故第 4 个中转用小键盘 Clear（usage 0x53 → kVK_ANSI_KeypadClear=71）：
        // macOS 无 NumLock 状态、系统零默认行为，即使 tap 失效泄漏也不输出字符。
        (0x52, 0x6E, 80,  .up),     // F19 (kVK_F19)
        (0x51, 0x6F, 90,  .down),   // F20 (kVK_F20)
        (0x50, 0x68, 105, .left),   // F13 (kVK_F13)
        (0x4F, 0x53, 71,  .right),  // Keypad Clear (kVK_ANSI_KeypadClear)
        // voice 键不纳入中转：语音功能走 ATVV(BLE)，与 HID 按键无关；中转只会产生无用 autorepeat 干扰。
    ]

    /// 方向键 → 原生方向键 keycode（就地改写放行用）。
    static let nativeArrowKeycode: [RemoteKey: Int64] = [
        .up: 126, .down: 125, .left: 123, .right: 124,   // kVK_UpArrow 等
    ]

    /// 方向键中转的三态分流判定（纯函数，供 self-test）。非方向键返回 nil。
    enum DirectionVerdict: Equatable {
        case rewrite(Int64)   // 就地改写为原生方向键 keycode 放行（含 autorepeat）
        case drop             // 吞弃（引擎路径上的 autorepeat）
        case engine           // 吞掉并转 ButtonEvent 喂 MappingEngine
    }
    static func directionVerdict(key: RemoteKey, isRepeat: Bool, route: TapRoute) -> DirectionVerdict? {
        guard let arrow = nativeArrowKeycode[key] else { return nil }
        if route.effectiveLayer == 0, !route.okDown, route.nativeDirections.contains(key) {
            return .rewrite(arrow)
        }
        return isRepeat ? .drop : .engine
    }

    static var keycodeMap: [Int64: RemoteKey] {
        Dictionary(uniqueKeysWithValues: table.map { ($0.keycode, $0.key) })
    }

    private static func run(_ mappingJSON: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property",
                       "--matching", #"{"VendorID":0x2717,"ProductID":0x32B8}"#,
                       "--set", #"{"UserKeyMapping":\#(mappingJSON)}"#]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// 安装重映射（幂等）
    static func install() {
        let entries = table.map {
            #"{"HIDKeyboardModifierMappingSrc":\#(0x700000000 + UInt64($0.src)),"HIDKeyboardModifierMappingDst":\#(0x700000000 + UInt64($0.dst))}"#
        }.joined(separator: ",")
        run("[\(entries)]")
    }

    /// 恢复原始按键
    static func uninstall() {
        run("[]")
    }
}

/// CGEventTap：捕获中转键（F13-F19），吞掉并转成 ButtonEvent。
/// 需要「辅助功能」权限。复用 HIDEngineDelegate 契约。
final class TapEngine: @unchecked Sendable {

    weak var delegate: HIDEngineDelegate?
    /// 方向键分流的快照来源（MappingEngine）。nil 时方向键全走引擎路径（安全默认）。
    weak var router: MappingEngine?
    private var tap: CFMachPort?
    /// 当前按压走「原生改写放行」路径的方向键（只在 tap 回调线程读写）。
    private var nativeHeldDirections: Set<RemoteKey> = []

    init(delegate: HIDEngineDelegate?) {
        self.delegate = delegate
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, ev, userInfo in
                let me = Unmanaged<TapEngine>.fromOpaque(userInfo!).takeUnretainedValue()
                return me.handle(type: type, event: ev)
            },
            userInfo: selfPtr) else {
            delegate?.hidLog("TAP 创建失败（需辅助功能权限）")
            delegate?.hidSeizeState(false)
            return
        }
        self.tap = tap
        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        KeyRemapper.install()
        delegate?.hidSeizeState(true)
        delegate?.hidLog("TAP 就绪，hidutil 中转映射已安装")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        KeyRemapper.uninstall()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            delegate?.hidLog("TAP 超时被禁用，已重新启用")
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = KeyRemapper.keycodeMap[keycode] else {
            return Unmanaged.passUnretained(event) // 非中转键，放行
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // 方向键三态分流：纯原生场景就地改写 keycode 放行（保住系统 autorepeat 与零延迟）。
        // 分流只在首次 keyDown 时按 MappingEngine 快照决定（无锁级 unfair lock，毫秒级
        // 陈旧可接受，见 TapRoute 注释）；autorepeat 与 keyUp 跟随该次按压记录的路径，
        // 避免按压中途层变化导致原生 down 配不上 up（系统卡住方向键）或引擎收到孤儿 up。
        if let arrow = KeyRemapper.nativeArrowKeycode[key] {
            let wasNative = nativeHeldDirections.contains(key)
            let verdict: KeyRemapper.DirectionVerdict
            if type == .keyDown, !isRepeat {
                verdict = KeyRemapper.directionVerdict(
                    key: key, isRepeat: false, route: router?.tapRoute ?? TapRoute())!
                if case .rewrite = verdict { nativeHeldDirections.insert(key) }
                else { nativeHeldDirections.remove(key) }
            } else {
                if type == .keyUp { nativeHeldDirections.remove(key) }
                verdict = wasNative ? .rewrite(arrow) : (isRepeat ? .drop : .engine)
            }
            switch verdict {
            case .rewrite(let a):
                event.setIntegerValueField(.keyboardEventKeycode, value: a)
                return Unmanaged.passUnretained(event)
            case .drop:
                return nil
            case .engine:
                // 落到下方吞掉上报
                break
            }
        } else if isRepeat {
            // 非方向中转键的 autorepeat 也吞弃：重复 keyDown 会不断重置
            // MappingEngine 的 hold 定时器，长按（如 ok→瞬时层）永远触发不了。
            return nil
        }
        // 吞掉中转键并上报（注意：外接键盘的真 F13-F20/小键盘Clear 也会被吞——Mac 键盘几乎没有这些键，可接受）
        delegate?.hidButton(ButtonEvent(key: key, isDown: type == .keyDown,
                                        timeNs: DispatchTime.now().uptimeNanoseconds))
        return nil
    }
}
