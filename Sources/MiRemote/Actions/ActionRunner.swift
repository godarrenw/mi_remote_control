import Foundation
import AppKit
import CoreGraphics

/// 动作执行器：把 Action 落成真正的系统事件/命令。
/// MappingEngine 在主线程调用 run(_:)。语音/层动作不由此处理（映射层负责）。
final class ActionRunner: ActionRunning, @unchecked Sendable {

    // MARK: - 键名 → keycode（ANSI 虚拟键码，来自 <HIToolbox/Events.h> kVK_*）
    // 覆盖遥控器默认配置常用键；用户自定义时按需扩展。
    static let keyCodes: [String: CGKeyCode] = [
        // 控制键
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forward_delete": 117,
        // 方向 / 导航
        "up_arrow": 126, "down_arrow": 125, "left_arrow": 123, "right_arrow": 124,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121,
        // 字母（ANSI 布局）
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        // 数字行
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        // 符号
        "equal": 24, "minus": 27, "right_bracket": 30, "left_bracket": 33,
        "quote": 39, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44,
        "period": 47, "grave": 50, "backtick": 50,
        // 功能键
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    // MARK: - 修饰键名 → (keycode, IOKit 设备位)
    // 设备位来自 DESIGN.md §4.1（IOLLEvent.h）：左右分明。
    // 通用 CGEventFlags mask 另外 OR，保证只读通用位的应用也识别。
    struct Modifier { let keyCode: CGKeyCode; let deviceBit: UInt64; let mask: CGEventFlags }
    static let modifiers: [String: Modifier] = [
        "left_cmd":    Modifier(keyCode: 55, deviceBit: 0x08,   mask: .maskCommand),
        "right_cmd":   Modifier(keyCode: 54, deviceBit: 0x10,   mask: .maskCommand),
        "left_shift":  Modifier(keyCode: 56, deviceBit: 0x02,   mask: .maskShift),
        "right_shift": Modifier(keyCode: 60, deviceBit: 0x04,   mask: .maskShift),
        "left_option": Modifier(keyCode: 58, deviceBit: 0x20,   mask: .maskAlternate),
        "right_option":Modifier(keyCode: 61, deviceBit: 0x40,   mask: .maskAlternate),
        "left_ctrl":   Modifier(keyCode: 59, deviceBit: 0x01,   mask: .maskControl),
        "right_ctrl":  Modifier(keyCode: 62, deviceBit: 0x2000, mask: .maskControl),
    ]

    private let source = CGEventSource(stateID: .combinedSessionState)

    /// M5 v2 浮层动作出口：GUI 模式接线（OverlayCenter，主线程自行切换）；
    /// CLI 模式无 GUI，保持 nil，仅记日志。写主线程/读引擎线程，赋值一次后只读。
    nonisolated(unsafe) static var onOverlay: ((String) -> Void)?

    // MARK: - ActionRunning
    func run(_ action: Action) {
        switch action {
        case .overlay(let name):
            if let hook = Self.onOverlay {
                DispatchQueue.main.async { hook(name) }
            } else {
                log("overlay 动作仅 GUI 模式可用: \(name)")
            }
        case .keyStroke(let key, let mods): keyStroke(key: key, mods: mods)
        case .system(let name):             system(name)
        case .openApp(let bundle):          openApp(bundle)
        case .shell(let cmd):               shell(cmd)
        // M4 高级动作
        case .windowCycle(let scope):       WindowSwitcher.cycle(scope: scope)
        case .tabJump(let dir, let index):  tabJump(dir: dir, index: index)
        case .focusInput:                   FocusInput.perform()
        case .mouseMode:                    MouseMode.shared.toggle()
        case .macro(let steps):             MacroEngine.shared.run(steps, runner: self)
        case .voice, .layerMomentary, .layerToggle, .none:
            // 这些由 MappingEngine / ATVV 侧处理，ActionRunner 忽略。
            log("ignore action handled elsewhere: \(action)")
        }
    }

    // MARK: - key_stroke
    private func keyStroke(key: String, mods: [String]) {
        guard let code = Self.keyCodes[key.lowercased()] else {
            log("unknown key name: \(key)"); return
        }
        // 累积修饰键的设备位与通用 mask。
        var flags = CGEventFlags(rawValue: 0)
        for name in mods {
            guard let m = Self.modifiers[name.lowercased()] else {
                log("unknown modifier: \(name)"); continue
            }
            flags.insert(CGEventFlags(rawValue: m.deviceBit))  // IOKit 设备位（左右精确）
            flags.insert(m.mask)                               // 通用位（兼容只读通用位的 app）
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            log("failed to create key event for \(key)"); return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - system
    private func system(_ name: String) {
        switch name {
        case "volume_up":   aux(NX_KEYTYPE_SOUND_UP)
        case "volume_down": aux(NX_KEYTYPE_SOUND_DOWN)
        case "mute":        aux(NX_KEYTYPE_MUTE)
        case "play_pause":  aux(NX_KEYTYPE_PLAY)
        case "next":        aux(NX_KEYTYPE_NEXT)
        case "prev", "previous": aux(NX_KEYTYPE_PREVIOUS)
        case "mission_control":
            // 直接打开 Mission Control.app 比合成 Ctrl+Up 可靠（合成键在部分 macOS 版本无效）。
            run(process: "/usr/bin/open", ["-a", "Mission Control"])
        case "launchpad":
            // macOS 26(Tahoe) 移除了 Launchpad.app。存在则开，否则退回 Spotlight(Cmd+Space)。
            if FileManager.default.fileExists(atPath: "/System/Applications/Launchpad.app") {
                run(process: "/usr/bin/open", ["/System/Applications/Launchpad.app"])
            } else {
                synth(keyCode: 49, deviceBit: 0x08, mask: .maskCommand) // space + left_cmd
            }
        case "spotlight":
            synth(keyCode: 49, deviceBit: 0x08, mask: .maskCommand)
        case "display_sleep":
            run(process: "/usr/bin/pmset", ["displaysleepnow"])
        case "lock_screen":
            // pmcp 无锁屏；用 CGSession 的私有工具最稳：osascript 触发系统锁屏键。
            run(process: "/usr/bin/pmset", ["displaysleepnow"]) // 熄屏（若系统设了立即锁定即锁屏）
            // 显式锁屏：调用登录窗口的 CGSession（不引私有 API，走命令行）。
            run(process: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
                ["-suspend"])
        case "screenshot":
            // Cmd+Shift+4 区域截图（DESIGN §3.2 system 列出截图）。
            synth(keyCode: 21, deviceBit: 0x08 | 0x02, mask: [.maskCommand, .maskShift]) // 4
        default:
            if !WorkspaceActions.perform(named: name) {
                log("unknown system action: \(name)")
            }
        }
    }

    // MARK: - tab_jump（DESIGN §4.3：Ghostty/浏览器/VS Code 通吃）
    /// index 模式：cmd+数字 直跳第 N 标签（1-9）；dir 模式：cmd+shift+[/] 相对切换。
    private func tabJump(dir: Int?, index: Int?) {
        if let index {
            guard (1...9).contains(index), let code = Self.keyCodes["\(index)"] else {
                log("tab_jump index 超范围(1-9): \(index)"); return
            }
            synth(keyCode: code, deviceBit: 0x08, mask: .maskCommand)                    // cmd+数字
        } else if let dir {
            let bracket = Self.keyCodes[dir >= 0 ? "right_bracket" : "left_bracket"]!
            synth(keyCode: bracket, deviceBit: 0x08 | 0x02, mask: [.maskCommand, .maskShift]) // cmd+shift+[/]
        } else {
            log("tab_jump 缺少 dir/index 参数")
        }
    }

    /// 合成一个「主键 + 修饰位」的组合键（供 mission_control/screenshot 复用）。
    private func synth(keyCode: CGKeyCode, deviceBit: UInt64, mask: CGEventFlags) {
        var flags = CGEventFlags(rawValue: deviceBit)
        flags.insert(mask)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    /// 发送一个媒体/音量 aux 按键（NSEvent systemDefined，subtype 8）。
    /// down(0x0A/0x0B 位组合) → up，两帧一对，模拟物理媒体键。
    private func aux(_ keyType: Int32) {
        func postAux(down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xA00) : NSEvent.ModifierFlags(rawValue: 0xB00)
            let data1 = (Int(keyType) << 16) | ((down ? 0xA : 0xB) << 8)
            guard let ev = NSEvent.otherEvent(with: .systemDefined,
                                              location: .zero,
                                              modifierFlags: flags,
                                              timestamp: 0,
                                              windowNumber: 0,
                                              context: nil,
                                              subtype: 8,   // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                              data1: data1,
                                              data2: -1) else { return }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
        postAux(down: true)
        postAux(down: false)
    }

    // MARK: - open_app
    private func openApp(_ bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            log("no app for bundle id: \(bundle)"); return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { [weak self] _, err in
            if let err = err { self?.log("openApp failed \(bundle): \(err)") }
        }
    }

    // MARK: - shell（独立进程组后台跑，不阻塞；10s 超时 SIGTERM 整组，2s 宽限后 SIGKILL 整组）
    // Foundation Process 不暴露 setpgroup，改用 posix_spawn：zsh 自成进程组，
    // 超时 kill(-pgid) 连同它派生的子进程/后台进程一起清掉（原实现只 terminate zsh 父进程）。
    private func shell(_ cmd: String) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)   // pgid = 子进程自身 pid
        var pid: pid_t = 0
        let words: [String] = ["/bin/zsh", "-c", cmd]
        var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
        argv.append(nil)
        let rc = posix_spawn(&pid, "/bin/zsh", nil, &attr, argv, environ)
        posix_spawnattr_destroy(&attr)
        argv.forEach { free($0) }
        guard rc == 0 else { log("shell spawn failed rc=\(rc)"); return }
        let group = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            // 进程组仍存活才发信号（组完全退出后 kill 返回 ESRCH，无害但省掉误杀窗口）。
            guard kill(-group, 0) == 0 else { return }
            kill(-group, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-group, SIGKILL) }
        }
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)   // 回收 zsh，避免僵尸进程
        }
    }

    /// 直接跑一个可执行文件（不经 shell），后台不阻塞。
    private func run(process path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { log("process launch failed \(path): \(error)") }
    }

    private func log(_ msg: String) { NSLog("[ActionRunner] %@", msg) }

    // MARK: - selfCheck（不发送事件，仅验证表正确性）
    static func selfCheck() -> Bool {
        guard !keyCodes.isEmpty, !modifiers.isEmpty else { return false }
        guard keyCodes["return"] == 36,
              keyCodes["right_arrow"] == 124,
              keyCodes["a"] == 0,
              keyCodes["tab"] == 48,
              keyCodes["space"] == 49 else { return false }
        guard modifiers["left_cmd"]?.deviceBit == 0x08,
              modifiers["right_cmd"]?.deviceBit == 0x10,
              modifiers["left_shift"]?.deviceBit == 0x02,
              modifiers["right_shift"]?.deviceBit == 0x04,
              modifiers["left_option"]?.deviceBit == 0x20,
              modifiers["right_option"]?.deviceBit == 0x40,
              modifiers["left_ctrl"]?.deviceBit == 0x01,
              modifiers["right_ctrl"]?.deviceBit == 0x2000 else { return false }
        return true
    }
}

// NX_KEYTYPE_* 常量（<IOKit/hidsystem/ev_keymap.h>），避免链接私有头，直接内联。
private let NX_KEYTYPE_SOUND_UP:   Int32 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
private let NX_KEYTYPE_MUTE:       Int32 = 7
private let NX_KEYTYPE_PLAY:       Int32 = 16
private let NX_KEYTYPE_NEXT:       Int32 = 17
private let NX_KEYTYPE_PREVIOUS:   Int32 = 18
