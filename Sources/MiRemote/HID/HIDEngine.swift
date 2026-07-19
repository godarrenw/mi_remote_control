import Foundation
import IOKit.hid

/// M2 HID 按键引擎。
///
/// 通过 `IOHIDManager` 匹配小米遥控器（VID 0x2717 / PID 0x32B8），把键盘页
/// (usagePage 0x07) 的原始按键翻译成 `RemoteKey`，经 `HIDEngineDelegate` 上报。
///
/// 打开策略：优先 `kIOHIDOptionsTypeSeizeDevice` 独占——系统收不到原始按键，
/// 杜绝「遥控器按一下、既走我们的映射又触发系统默认」的双触发。独占失败则降级
/// 为 `kIOHIDOptionsTypeNone` 监听模式：仍能读到按键，但**系统同样会处理它们**。
///
/// ponytail(M2): 监听模式下要真正抑制系统默认行为需要 CGEventTap 把遥控器事件吞掉
/// （用 eventSourceUserData 魔数标记自己合成的事件避免误吞，见 DESIGN §3.5）。
/// M2 先不做——降级路径只保证能读到键，抑制留给后续里程碑。
///
/// `@unchecked Sendable`: IOHIDManager 的回调在我们调度的 runloop 线程上执行
/// （这里是主 runloop），实例被以 opaque 指针形式传进 C 回调。可变状态仅有
/// `seized`，且只在该 runloop 线程读写，故无需额外同步；delegate 为 weak 只读。
final class HIDEngine: @unchecked Sendable {

    private static let vendorID: Int  = 0x2717
    private static let productID: Int = 0x32B8
    private static let keyboardUsagePage: UInt32 = 0x07
    /// 探针发现的噪声元素 usage（-1），需忽略。
    private static let noiseUsage: UInt32 = 0xFFFFFFFF

    private weak var delegate: HIDEngineDelegate?
    private var manager: IOHIDManager?
    /// 当前是否处于独占（seize）模式。仅在 runloop 回调线程访问。
    private var seized = false

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

        openManager(mgr)
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        seized = false
    }

    // MARK: - 打开 / 降级

    /// 先试独占，失败降级监听。热插拔时 manager 会用同样的 option 自动打开新设备。
    private func openManager(_ mgr: IOHIDManager) {
        let seizeResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if seizeResult == kIOReturnSuccess {
            seized = true
            delegate?.hidLog("HID: 已独占打开设备 (seize)")
            delegate?.hidSeizeState(true)
            return
        }

        // 独占失败：清掉半开状态后以监听模式重开。
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        let listenResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        seized = false
        if listenResult == kIOReturnSuccess {
            delegate?.hidLog(String(format: "HID: 独占失败(0x%08X)，降级为监听模式（系统仍会处理按键）", seizeResult))
        } else {
            delegate?.hidLog(String(format: "HID: 打开失败 seize=0x%08X listen=0x%08X", seizeResult, listenResult))
        }
        delegate?.hidSeizeState(false)
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
        // 若当前处于降级监听模式，插入是重新争取独占的机会：单独对该设备尝试 seize。
        guard !seized else { return }
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if r == kIOReturnSuccess {
            seized = true
            delegate?.hidLog("HID: 热插拔后升级为独占 (seize)")
            delegate?.hidSeizeState(true)
        }
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        delegate?.hidLog("HID: 设备移除")
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
