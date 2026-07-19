import Foundation
import IOKit.hid

/// M2 HID 按键引擎。
///
/// 通过 `IOHIDManager` 匹配小米遥控器（VID 0x2717 / PID 0x32B8），把键盘页
/// (usagePage 0x07) 的原始按键翻译成 `RemoteKey`，经 `HIDEngineDelegate` 上报。
///
/// 打开策略：直接 `kIOHIDOptionsTypeNone` 监听模式。
/// 实机已证实 macOS 禁止用户态 seize 蓝牙键盘（0xE00002C1）；且对同一
/// IOHIDManager「seize 失败 → Close → 重开」后，重开虽返回 success，
/// 已枚举设备却不会真正重新打开——InputValue 回调永远收不到事件
/// （即交接文档记录的 back 键 0xF1 事件数=0 的根因）。
/// 系统默认行为的抑制由 hidutil 中转 + CGEventTap 负责（见 KeyRemapper）。
///
/// `@unchecked Sendable`: IOHIDManager 的回调在我们调度的 runloop 线程上执行
/// （这里是主 runloop），实例被以 opaque 指针形式传进 C 回调，无可变状态；
/// delegate 为 weak 只读。
final class HIDEngine: @unchecked Sendable {

    private static let vendorID: Int  = 0x2717
    private static let productID: Int = 0x32B8
    private static let keyboardUsagePage: UInt32 = 0x07
    /// 探针发现的噪声元素 usage（-1），需忽略。
    private static let noiseUsage: UInt32 = 0xFFFFFFFF

    private weak var delegate: HIDEngineDelegate?
    private var manager: IOHIDManager?

    /// 设备接入/移除通知（main 接线：蓝牙重连后重装 hidutil 映射 / 移除后复位输入状态）。
    /// 回调线程 = manager 调度的 runloop 线程。
    var onDeviceMatched: (() -> Void)?
    var onDeviceRemoved: (() -> Void)?

    init(delegate: HIDEngineDelegate?) {
        self.delegate = delegate
    }

    // MARK: - 生命周期

    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(IOOptionBits(kIOHIDOptionsTypeNone)))
        self.manager = mgr

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String:  Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        // self 以 unretained opaque 指针传进 C 回调；HIDEngine 生命周期覆盖 manager。
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, HIDEngine.inputValueCallback, ctx)
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, HIDEngine.deviceMatchedCallback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, HIDEngine.deviceRemovedCallback, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // 只走监听模式，绝不 seize——失败后 Close 重开会让 manager 收不到任何事件。
        let ret = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if ret == kIOReturnSuccess {
            delegate?.hidLog("HID: 监听模式已打开")
        } else {
            delegate?.hidLog(String(format: "HID: 打开失败 0x%08X（需要输入监控权限？）", ret))
        }
        delegate?.hidSeizeState(false)
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    // MARK: - 事件处理（回调线程）

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        guard usagePage == Self.keyboardUsagePage else { return }

        let usage = IOHIDElementGetUsage(element)
        // 探针噪声：usage=0xFFFFFFFF(-1) 的元素直接丢弃。
        guard usage != Self.noiseUsage else { return }

        let isDown = IOHIDValueGetIntegerValue(value) != 0

        guard let key = RemoteKey.usageMap[usage] else {
            delegate?.hidLog(String(format: "HID: 未知 usage 0x%02X (down=%@)", usage, isDown ? "1" : "0"))
            return
        }

        let event = ButtonEvent(key: key, isDown: isDown, timeNs: DispatchTime.now().uptimeNanoseconds)
        delegate?.hidButton(event)
    }

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        delegate?.hidLog("HID: 设备接入")
        onDeviceMatched?()
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        delegate?.hidLog("HID: 设备移除")
        onDeviceRemoved?()
    }

    // MARK: - C 回调蹦床（无捕获，可转 @convention(c) 指针）

    private static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let engine = Unmanaged<HIDEngine>.fromOpaque(context).takeUnretainedValue()
        engine.handleInputValue(value)
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let engine = Unmanaged<HIDEngine>.fromOpaque(context).takeUnretainedValue()
        engine.handleDeviceMatched(device)
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let engine = Unmanaged<HIDEngine>.fromOpaque(context).takeUnretainedValue()
        engine.handleDeviceRemoved(device)
    }
}
