import Foundation
import Carbon
import CoreGraphics

/// 通用语音触发器：把"遥控器语音键按下/松开"翻译成目标语音工具的热键动作。
/// 覆盖常见语音转文字工具的三种触发模式：
///   hold   按住说话（按下=keyDown，松开=keyUp）——Typeless/superwhisper 类
///   tap    单击开、再击关——豆包"按一下开始长录音"设置
///   double 双击开、单击关——豆包默认设置
/// 可选先切输入法（豆包是 IME 需要切；独立 app 传 nil）。
/// 需要「辅助功能」权限（合成 CGEvent）。
struct VoiceTriggerConfig {
    enum Mode: String { case hold, tap, double }

    var keyName: String = "right_option"
    var mode: Mode = .hold
    var imeBundlePrefix: String? = "com.bytedance.inputmethod"

    /// 键名 → (keycode, 修饰 flag, IOKit 左右设备位)。普通键两项为 nil。
    static let keyTable: [String: (CGKeyCode, CGEventFlags?, UInt64?)] = [
        "left_option":  (58, .maskAlternate, 0x20),
        "right_option": (61, .maskAlternate, 0x40),
        "left_cmd":     (55, .maskCommand,   0x08),
        "right_cmd":    (54, .maskCommand,   0x10),
        "left_shift":   (56, .maskShift,     0x02),
        "right_shift":  (60, .maskShift,     0x04),
        "left_ctrl":    (59, .maskControl,   0x01),
        "right_ctrl":   (62, .maskControl,   0x2000),
        "fn":           (63, .maskSecondaryFn, nil),
        "f5":           (96, nil, nil),
        "f13":          (105, nil, nil),
    ]
}

enum VoiceTrigger {

    static var config = VoiceTriggerConfig()

    private static var savedInputSource: TISInputSource?
    private static let queue = DispatchQueue(label: "com.miremote.voicetrigger")

    // MARK: - 输入法切换

    /// macOS 26 起，Text Input Source (TIS) API 会断言调用者位于主队列；
    /// 语音触发本身运行在专用串行队列，因此所有 TIS 调用都必须经这里切回主队列。
    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private static func findInputSource(bundlePrefix: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        for src in list {
            guard let ptr = TISGetInputSourceProperty(src, kTISPropertyBundleID) else { continue }
            let bundle = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            if bundle.hasPrefix(bundlePrefix),
               let catPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) {
                let cat = Unmanaged<CFString>.fromOpaque(catPtr).takeUnretainedValue() as String
                if cat == (kTISCategoryKeyboardInputSource as String) { return src }
            }
        }
        return nil
    }

    private static func switchIMEIfNeeded() {
        guard let prefix = config.imeBundlePrefix else { return }
        let didSwitch = onMain {
            guard let target = findInputSource(bundlePrefix: prefix) else {
                FileHandle.standardError.write("未找到目标输入法（\(prefix)*）\n".data(using: .utf8)!)
                return false
            }
            if savedInputSource == nil {
                savedInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            }
            TISSelectInputSource(target)
            return true
        }
        if didSwitch { usleep(150_000) } // 在工作队列等待输入法完成切换，不阻塞主线程
    }

    private static func restoreIMEIfNeeded() {
        guard config.imeBundlePrefix != nil else { return }
        queue.asyncAfter(deadline: .now() + 4.0) { // 等识别文本完全上屏再还原，过早切走会把语音条孤儿化
            onMain {
                if let saved = savedInputSource {
                    TISSelectInputSource(saved)
                    savedInputSource = nil
                }
            }
        }
    }

    // MARK: - 按键合成

    private static func post(down: Bool) {
        guard let (keycode, flag, deviceBit) = VoiceTriggerConfig.keyTable[config.keyName] else {
            FileHandle.standardError.write("未知触发键名: \(config.keyName)\n".data(using: .utf8)!)
            return
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: down) else { return }
        if let flag {
            // 修饰键的真实事件是 flagsChanged：按下=带修饰位，抬起=清空。
            // 直接发 keyDown/keyUp 型事件豆包等监听方看不见。
            ev.type = .flagsChanged
            var flags: CGEventFlags = []
            if down {
                flags.insert(flag)
                if let deviceBit { flags.insert(CGEventFlags(rawValue: deviceBit)) }
            }
            ev.flags = flags
        }
        ev.post(tap: .cghidEventTap)
    }

    private static func tap() {
        post(down: true)
        usleep(25_000)
        post(down: false)
    }

    // MARK: - 对外接口（异步，不阻塞 BLE queue）

    // hold 模式的抖动防护：
    // 遥控器语音键存在抖动（极短的 START/STOP 对），若如实转发会变成"Option 极短点按"，
    // 被豆包当成"单击=开始长录音"。两道防线：
    //  1) 松开去抖：收到 end 后等 250ms 再真正松键，期间来了新 begin 则合并（不重复按下）
    //  2) 最短按住：Option 至少按住 600ms 再松，避免落入"单击"判定
    private static var isDown = false
    private static var downAtNs: UInt64 = 0
    private static var releaseWork: DispatchWorkItem?
    private static let minHoldMs: UInt64 = 1000
    private static let releaseDebounceMs = 250

    /// 遥控器语音键按下
    static func begin() {
        queue.async {
            releaseWork?.cancel()
            releaseWork = nil
            switch config.mode {
            case .hold:
                if isDown { return } // 抖动合并：仍按着，无需重按
                switchIMEIfNeeded()
                post(down: true)
                isDown = true
                downAtNs = DispatchTime.now().uptimeNanoseconds
            case .tap:
                switchIMEIfNeeded()
                tap()
            case .double:
                switchIMEIfNeeded()
                tap(); usleep(80_000); tap()
            }
        }
    }

    /// 遥控器语音键松开
    static func end() {
        queue.async {
            switch config.mode {
            case .hold:
                guard isDown else { return }
                let heldMs = (DispatchTime.now().uptimeNanoseconds - downAtNs) / 1_000_000
                let extraForMinHold = heldMs >= minHoldMs ? 0 : Int(minHoldMs - heldMs)
                let wait = max(extraForMinHold, releaseDebounceMs)
                let work = DispatchWorkItem {
                    post(down: false)
                    isDown = false
                    restoreIMEIfNeeded()
                }
                releaseWork = work
                queue.asyncAfter(deadline: .now() + .milliseconds(wait), execute: work)
            case .tap, .double:
                tap()
                restoreIMEIfNeeded()
            }
        }
    }
}
