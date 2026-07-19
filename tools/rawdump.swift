// 原始 HID report 探针：抓遥控器设备原始字节（在 hidutil 重映射之前）
// swiftc -O tools/rawdump.swift -o /tmp/rawdump && /tmp/rawdump
import Foundation
import IOKit.hid

let VID = 0x2717, PID = 0x32B8
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID] as CFDictionary)

let bufSize = 64
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
let cb: IOHIDReportCallback = { _, _, _, _, reportID, report, len in
    let bytes = (0..<len).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
    print("report id=\(reportID) len=\(len): \(bytes)")
}

// device 层注册原始 report 回调
let matchCb: IOHIDDeviceCallback = { _, _, _, device in
    IOHIDDeviceRegisterInputReportCallback(device, buf, bufSize, cb, nil)
    print("device matched, report callback registered")
}
IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCb, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
if r != kIOReturnSuccess { print(String(format: "打开失败 0x%08X", r)); exit(1) }
print("== 就绪：请依次按 上 下 左 右 OK 返回 主页 菜单 TV 音量+ 音量- 各一下（40 秒）==")
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("== 结束 =="); exit(0) }
RunLoop.main.run()
