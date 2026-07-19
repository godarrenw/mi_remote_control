// HID 探针：监听小米遥控器（VID 0x2717 / PID 0x32B8）的按键，打印 usagePage/usage
// swiftc -O tools/hidprobe.swift -o /tmp/hidprobe && /tmp/hidprobe
import Foundation
import IOKit.hid

let VID = 0x2717, PID = 0x32B8

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID]
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

let cb: IOHIDValueCallback = { _, _, _, value in
    let elem = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(elem)
    let usage = IOHIDElementGetUsage(elem)
    let intVal = IOHIDValueGetIntegerValue(value)
    // 只关心按下（intVal=1），忽略松开与常量元素
    guard intVal != 0 else { return }
    print(String(format: "page=0x%02X usage=0x%02X (%d) val=%d", page, usage, usage, usage, intVal))
}
IOHIDManagerRegisterInputValueCallback(mgr, cb, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let ret = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
if ret != kIOReturnSuccess {
    print(String(format: "IOHIDManagerOpen 失败: 0x%08X（需要输入监控权限）", ret))
    exit(1)
}
print("== 探针就绪：请依次按 上/下/左/右/OK/返回/主页/菜单/TV/音量+/音量-/电源/语音 各一下（60 秒）==")
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("== 结束 =="); exit(0) }
RunLoop.main.run()
