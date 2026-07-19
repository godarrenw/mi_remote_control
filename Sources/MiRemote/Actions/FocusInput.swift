import AppKit
import ApplicationServices
import CoreGraphics
import os

/// 自动聚焦前台 app 的文本输入框（DESIGN §4.4，三级兜底）：
///   ① 终端类 app（TUI 无独立 AX 文本框）：前置窗口即聚焦输入行，到此为止；
///   ② AX 树 BFS 收集可见输入候选，按“编辑区优先、靠近窗口底部、搜索框降权”评分，
///      避免 Electron App 中总是命中侧栏搜索框，再设 AXFocused=true
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

        guard let field = findTextInput(in: root) else {
            log("聚焦编辑区失败：前台 App 未暴露可见文本输入元素")
            return
        }

        // ② AXFocused
        if AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
           boolAttribute(field, kAXFocusedAttribute as CFString) == true {
            return
        }
        // ③ 中心点合成左键单击
        if let c = center(of: field) { click(at: c) }
    }

    // MARK: - AX 树 BFS（深度/节点数上限防卡死）

    private static let maxNodes = 2500
    private static let maxDepth = 14
    private static let targetRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]

    private struct Candidate {
        let element: AXUIElement
        let score: Int
    }

    private static func findTextInput(in root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        var visited = 0
        let rootFrame = frame(of: root)
        var best: Candidate?
        while head < queue.count, visited < maxNodes {
            let (el, depth) = queue[head]
            head += 1
            visited += 1
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, targetRoles.contains(role),
               let candidateFrame = frame(of: el), isVisible(candidateFrame, within: rootFrame),
               boolAttribute(el, kAXEnabledAttribute as CFString) != false {
                let candidate = Candidate(
                    element: el,
                    score: candidateScore(role: role,
                                          label: label(of: el),
                                          frame: candidateFrame,
                                          rootFrame: rootFrame,
                                          focused: boolAttribute(el, kAXFocusedAttribute as CFString) == true,
                                          editable: boolAttribute(el, "AXEditable" as CFString) == true)
                )
                if best == nil || candidate.score > best!.score { best = candidate }
            }
            guard depth < maxDepth else { continue }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                for k in kids { queue.append((k, depth + 1)) }
            }
        }
        return best?.element
    }

    /// 纯函数评分：对话编辑区通常是靠近窗口底部的 TextArea；
    /// SearchField 及 label 含 search/find 的元素显著降权。
    static func candidateScore(role: String, label: String, frame: CGRect,
                               rootFrame: CGRect?, focused: Bool, editable: Bool) -> Int {
        var score: Int
        switch role {
        case "AXTextArea": score = 500
        case "AXTextField": score = 300
        case "AXComboBox": score = 180
        case "AXSearchField": score = -100
        default: score = 0
        }
        if focused { score += 120 }
        if editable { score += 180 }
        let lower = label.lowercased()
        if ["message", "prompt", "composer", "chat", "消息", "输入", "编辑"]
            .contains(where: lower.contains) { score += 350 }
        if ["search", "find", "filter", "搜索", "查找", "过滤"]
            .contains(where: lower.contains) { score -= 500 }
        if let rootFrame, rootFrame.height > 0 {
            let relativeBottom = (frame.midY - rootFrame.minY) / rootFrame.height
            score += Int(max(0, min(1, relativeBottom)) * 300)
        }
        score += min(160, Int((frame.width * frame.height) / 2_000))
        return score
    }

    // MARK: - 几何 & 点击兜底

    private static func frame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, CFGetTypeID(p) == AXValueGetTypeID(),
              let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((p as! AXValue), .cgPoint, &pos),
              AXValueGetValue((s as! AXValue), .cgSize, &size) else { return nil }
        guard size.width >= 2, size.height >= 2 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func center(of el: AXUIElement) -> CGPoint? {
        guard let frame = frame(of: el) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private static func isVisible(_ frame: CGRect, within rootFrame: CGRect?) -> Bool {
        // 从 focused window 遍历时，与窗口实际几何相交比 NSScreen
        // 更可靠（AX 与 AppKit 在多显示器上的 y 轴原点定义不同）。
        if let rootFrame { return rootFrame.intersects(frame) }
        return frame.maxX > 0 && frame.maxY > 0
    }

    private static func boolAttribute(_ el: AXUIElement, _ name: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((ref as! CFBoolean))
    }

    private static func label(of el: AXUIElement) -> String {
        [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
         kAXHelpAttribute as CFString, "AXPlaceholderValue" as CFString]
            .compactMap { name -> String? in
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, name, &ref) == .success else { return nil }
                return ref as? String
            }
            .joined(separator: " ")
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
