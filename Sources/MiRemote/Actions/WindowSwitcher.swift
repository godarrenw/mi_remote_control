import AppKit
import ApplicationServices
import CoreGraphics

/// 窗口切换（DESIGN §4.2）：
///   - scope "app"   ：同 app 多窗口循环（AX 枚举 → 下一个 → AXRaise）
///   - scope "global"：全局 MRU 循环（CGWindowList z 序即近似 MRU，取下一窗口 activate + AXRaise）
/// AX 调用失败一律静默降级为 NSRunningApplication.activate()，全程不抛异常。
/// 需要「辅助功能」权限（AXRaise）；无「屏幕录制」权限时窗口标题可能为空，仅影响标题匹配精度。
enum WindowSwitcher {

    struct WindowInfo {
        let pid: pid_t
        let windowID: CGWindowID
        let title: String
    }

    // MARK: - 纯逻辑（可单测）

    /// 循环取下一个下标（count<=0 时返回 0）。
    static func nextIndex(after i: Int, count: Int) -> Int {
        count <= 0 ? 0 : ((i + 1) % count + count) % count
    }

    /// 从 MRU 候选列表（前到后）里挑全局切换目标：跳过第 0 个（当前前台），有标题的优先。
    static func pickGlobalTarget(_ wins: [WindowInfo]) -> WindowInfo? {
        guard wins.count > 1 else { return nil }
        let rest = wins.dropFirst()
        return rest.first(where: { !$0.title.isEmpty }) ?? rest.first
    }

    // MARK: - 窗口枚举

    /// 可见窗口（layer 0，z 序前到后 ≈ MRU），排除本进程。
    static func visibleWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPid = getpid()
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  let wid = d[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return WindowInfo(pid: pid, windowID: wid,
                              title: d[kCGWindowName as String] as? String ?? "")
        }
    }

    // MARK: - 执行入口

    static func cycle(scope: String) {
        scope == "global" ? cycleGlobal() : cycleApp()
    }

    /// 同 app 窗口循环：AX 枚举窗口 → 当前 focused 的下一个 → raise。失败降级 activate。
    private static func cycleApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement], wins.count > 1 else {
            app.activate()   // 降级：单窗口或 AX 不可用
            return
        }
        var focusedRef: CFTypeRef?
        var current = 0
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let f = focusedRef {
            current = wins.firstIndex(where: { CFEqual($0, f) }) ?? 0
        }
        raise(wins[nextIndex(after: current, count: wins.count)], app: app)
    }

    /// 全局 MRU 循环：z 序第二个（≈上一个用过的）窗口所属 app 前置 + 按标题 AXRaise 精确定位。
    private static func cycleGlobal() {
        guard let target = pickGlobalTarget(visibleWindows()),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        app.activate()
        guard !target.title.isEmpty else { return } // 无标题：activate 已尽力
        let axApp = AXUIElementCreateApplication(target.pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return } // AX 失败：静默降级
        for w in wins {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
               let s = t as? String, s == target.title {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                return
            }
        }
    }

    /// AXRaise + activate；AX 失败静默（activate 已保证 app 前置）。
    private static func raise(_ window: AXUIElement, app: NSRunningApplication) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate()
    }

    // MARK: - M5 v2 窗口选择器数据源与激活

    /// 选择器条目：CGWindowList 窗口 + 所属 App 的展示信息。
    struct PickerEntry {
        let window: WindowInfo
        let appName: String
        let bundleID: String?
    }

    /// 选择器候选（z 序前到后 ≈ MRU）。
    /// - currentAppOnly=true：只列 pid == frontPid 的窗口（范围「当前 App」）。
    /// - false：全部可见窗口（范围「所有 App」）。
    static func pickerEntries(currentAppOnly: Bool, frontPid: pid_t?) -> [PickerEntry] {
        visibleWindows().compactMap { info in
            if currentAppOnly, info.pid != frontPid { return nil }
            guard let app = NSRunningApplication(processIdentifier: info.pid) else { return nil }
            return PickerEntry(window: info,
                               appName: app.localizedName ?? "未知应用",
                               bundleID: app.bundleIdentifier)
        }
    }

    /// 激活指定窗口：app 前置 + 按标题 AXRaise 精确定位（复用全局切换的成熟逻辑）。
    static func activate(_ target: WindowInfo) {
        guard let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        app.activate()
        guard !target.title.isEmpty else { return }
        let axApp = AXUIElementCreateApplication(target.pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return }
        for w in wins {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
               let s = t as? String, s == target.title {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                return
            }
        }
    }
}
