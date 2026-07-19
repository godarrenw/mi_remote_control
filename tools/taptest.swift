// CGEventTap 探针：监听全局 keyDown/keyUp，打印 keycode
// 用来验证 hidutil 重映射后的中转键能否被 CGEventTap 捕获
// swiftc -O tools/taptest.swift -o /tmp/taptest && /tmp/taptest
import Foundation
import CoreGraphics

let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
let cb: CGEventTapCallBack = { _, type, ev, _ in
    let kc = ev.getIntegerValueField(.keyboardEventKeycode)
    let t = type == .keyDown ? "DOWN" : "UP  "
    FileHandle.standardError.write("\(t) keycode=\(kc)\n".data(using: .utf8)!)
    return Unmanaged.passUnretained(ev)
}
guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                  options: .listenOnly, eventsOfInterest: mask,
                                  callback: cb, userInfo: nil) else {
    FileHandle.standardError.write("tap 创建失败（需辅助功能权限）\n".data(using: .utf8)!); exit(1)
}
let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
FileHandle.standardError.write("== CGEventTap 就绪，请按菜单键（60秒）==\n".data(using: .utf8)!)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
RunLoop.main.run()
