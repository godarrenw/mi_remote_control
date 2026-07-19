// 事件诊断：对比真实按键与合成按键的字段差异
// 用法：swiftc -O tools/eventmon.swift -o /tmp/eventmon && /tmp/eventmon
// 前 10 秒：请真人按一次左 Option；第 12 秒自动发一次合成左 Option；共运行 20 秒。
import Foundation
import CoreGraphics

func describe(_ type: CGEventType, _ ev: CGEvent) -> String {
    let keycode = ev.getIntegerValueField(.keyboardEventKeycode)
    let flags = ev.flags.rawValue
    let srcState = ev.getIntegerValueField(.eventSourceStateID)
    let srcPID = ev.getIntegerValueField(.eventSourceUnixProcessID)
    let autorep = ev.getIntegerValueField(.keyboardEventAutorepeat)
    let ts = ev.timestamp
    let typeName: String
    switch type {
    case .keyDown: typeName = "keyDown"
    case .keyUp: typeName = "keyUp"
    case .flagsChanged: typeName = "flagsChanged"
    default: typeName = "type\(type.rawValue)"
    }
    return "\(typeName) keycode=\(keycode) flags=0x\(String(flags, radix: 16)) srcState=\(srcState) srcPID=\(srcPID) autorep=\(autorep) ts=\(ts)"
}

let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: mask,
                                  callback: { _, type, ev, _ in
                                      print(describe(type, ev))
                                      return Unmanaged.passUnretained(ev)
                                  },
                                  userInfo: nil) else {
    print("无法创建 event tap（需要辅助功能/输入监控权限）")
    exit(1)
}
let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("== 监听开始：请在 15 秒内按一次真实的左 Option ==")

DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    print("== 现在发送合成左 Option（flagsChanged 版本）==")
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: down) else { continue }
        ev.type = .flagsChanged
        ev.flags = down ? [.maskAlternate, CGEventFlags(rawValue: 0x20)] : []
        ev.post(tap: .cghidEventTap)
        usleep(120_000)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
    print("== 结束 ==")
    exit(0)
}
RunLoop.main.run()
