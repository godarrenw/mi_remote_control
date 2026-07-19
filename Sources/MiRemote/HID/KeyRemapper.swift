import Foundation
import CoreGraphics

/// M2 按键接管的最终架构（实机验证 2026-07-19）：
/// macOS 不允许用户态 seize 蓝牙 HID 键盘（0xE00002C1），IOHID 独占不可行。
/// 正路：hidutil 把有副作用的键在内核层重映射到 F13-F19（系统零默认行为），
/// 再用 CGEventTap 捕获并吞掉这些中转键，反查回原始键触发动作。
/// 方向键/音量键 v1 保持系统原生（默认行为即所需）。
// ponytail: 方向/音量键暂不接管，层/手势要拦它们时再把这两组也搬进中转表

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
        // voice 键不纳入中转：语音功能走 ATVV(BLE)，与 HID 按键无关；中转只会产生无用 autorepeat 干扰。
    ]

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
    private var tap: CFMachPort?

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
        // 吞掉中转键并上报（注意：外接键盘的真 F13-F19 也会被吞——Mac 键盘几乎没有这些键，可接受）
        delegate?.hidButton(ButtonEvent(key: key, isDown: type == .keyDown,
                                        timeNs: DispatchTime.now().uptimeNanoseconds))
        return nil
    }
}
