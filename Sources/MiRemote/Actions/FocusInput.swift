import AppKit
import ApplicationServices
import CoreGraphics
import os

/// 自动聚焦前台 app 的文本输入框（DESIGN §4.4，三级兜底）：
///   ① 终端类 app（TUI 无独立 AX 文本框）：前置窗口即聚焦输入行，到此为止；
///   ② AX 树 BFS 找 AXTextArea/AXTextField 设 AXFocused=true
///      （Electron/Chromium 默认不暴露 AX 树，先写 AXManualAccessibility /
///       AXEnhancedUserInterface=true 各一次再遍历；BFS 有深度/节点数上限防卡死）；
///   ③ AX 拿到输入框 frame，合成鼠标左键点其中心。
/// 每级失败静默降级下一级，全程不抛异常。需要「辅助功能」权限。
enum FocusInput {

    // MARK: - 终端类 app 白名单（纯数据，可单测）

    static let terminalBundles: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "co.zeit.hyper",
    ]

    /// 配置追加的终端 bundle id（settings.terminalApps）。启动/applyConfig 时主线程
    /// 整体替换、映射动作线程读——Swift 集合并发读写是数据竞争（可能崩溃），锁保护。
    private static let extraLock = OSAllocatedUnfairLock(initialState: Set<String>())
    static var extraTerminalBundles: Set<String> {
        get { extraLock.withLock { $0 } }
        set { extraLock.withLock { $0 = newValue } }
    }

    static func isTerminalApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundles.contains(bundleID) || extraTerminalBundles.contains(bundleID)
    }

    // MARK: - 入口

    static func perform() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        // ① 终端类：前置窗口即聚焦输入行
        if isTerminalApp(app.bundleIdentifier) {
            app.activate()
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium 的 AX 树默认关闭，先各写一次开启开关（对其他 app 无害，失败忽略）
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        // 优先从 focused window 子树找（更快更准），拿不到就从 app 根找
        var root = axApp
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let v = winRef, CFGetTypeID(v) == AXUIElementGetTypeID() {
            root = (v as! AXUIElement)
        }

        guard let field = findTextInput(in: root) else { return } // 找不到输入框：静默放弃

        // ② AXFocused
        if AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return
        }
        // ③ 中心点合成左键单击
        if let c = center(of: field) { click(at: c) }
    }

    // MARK: - AX 树 BFS（深度/节点数上限防卡死）

    private static let maxNodes = 2500
    private static let maxDepth = 14
    private static let targetRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField"]

    private static func findTextInput(in root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        var visited = 0
        while head < queue.count, visited < maxNodes {
            let (el, depth) = queue[head]
            head += 1
            visited += 1
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, targetRoles.contains(role) {
                return el
            }
            guard depth < maxDepth else { continue }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                for k in kids { queue.append((k, depth + 1)) }
            }
        }
        return nil
    }

    // MARK: - 几何 & 点击兜底

    private static func center(of el: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, CFGetTypeID(p) == AXValueGetTypeID(),
              let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((p as! AXValue), .cgPoint, &pos),
              AXValueGetValue((s as! AXValue), .cgSize, &size) else { return nil }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    private static func click(at point: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
