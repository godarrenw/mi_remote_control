import AppKit
import ApplicationServices
import CoreGraphics

/// 窗口切换（DESIGN §4.2）：
///   - scope "app"   ：同 app 多窗口循环（AX 枚举 → 下一个 → AXRaise）
///   - scope "global"：全局 MRU 循环（CGWindowList z 序即近似 MRU，取下一窗口 activate + AXRaise）
/// AX 调用失败一律静默降级为 NSRunningApplication.activate()，全程不抛异常。
/// 需要「辅助功能」权限（AXRaise）；无「屏幕录制」权限时窗口标题可能为空。
///
/// 目标窗口定位以 **CGWindowID** 为准（私有符号 `_AXUIElementGetWindow`，AltTab/yabai 同款），
/// 标题只做最后兜底——同 App 多窗口标题相同/为空时，按标题匹配会把三个窗口切成同一个（2026-08-26 实测 bug）。
enum WindowSwitcher {

    static let visibleListOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    static let globalListOptions: CGWindowListOption = [.optionAll, .excludeDesktopElements]

    struct WindowInfo {
        let pid: pid_t
        let windowID: CGWindowID
        let title: String
    }

    // MARK: - AX ↔ CGWindowID

    /// AX 窗口元素对应的 CGWindowID；私有 API 失败返回 nil（此时退回标题匹配）。
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success && wid != 0 ? wid : nil
    }

    /// 某 App 当前聚焦窗口的 CGWindowID（MRU 压栈用）。
    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return windowID(of: ref as! AXUIElement)
    }

    /// 在 App 的 AX 窗口列表里定位目标：ID 精确匹配 → 标题兜底。
    static func axWindow(for target: WindowInfo, app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return nil }
        if let byID = wins.first(where: { windowID(of: $0) == target.windowID }) { return byID }
        guard !target.title.isEmpty else { return nil }
        return wins.first { w in
            var t: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success
                && (t as? String) == target.title
        }
    }

    // MARK: - 原生标签页（AXTabGroup）

    /// 一个 App 里所有窗口的标签按钮（AXTabButton）及其标题。
    /// macOS 原生标签页未选中时是被 order-out 的 NSWindow：CGWindowList 里有、不在任何 Space、
    /// **AX 窗口列表里没有**（Ghostty 三个标签页实测只暴露当前页）。要切过去只能按它的标签按钮。
    static func tabButtons(pid: pid_t) -> [(element: AXUIElement, title: String)] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)   // 无响应 App 不拖慢选择器
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return [] }
        var out: [(AXUIElement, String)] = []
        for w in wins { collectTabButtons(w, depth: 0, into: &out) }
        return out
    }

    private static func axString(_ e: AXUIElement, _ attr: String) -> String? {
        var r: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &r) == .success ? r as? String : nil
    }

    private static func collectTabButtons(_ e: AXUIElement, depth: Int, into out: inout [(AXUIElement, String)]) {
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return }
        if axString(e, kAXRoleAttribute) == "AXTabGroup" {
            for k in kids where axString(k, kAXSubroleAttribute) == "AXTabButton" {
                out.append((k, axString(k, kAXTitleAttribute) ?? ""))
            }
            return
        }
        guard depth < 4 else { return }   // 标签栏都在窗口顶层附近，不深挖整棵树
        for k in kids { collectTabButtons(k, depth: depth + 1, into: &out) }
    }

    /// 幽灵条目过滤纯逻辑（自测覆盖）：AX 列表里没有的窗口（隐藏标签页 / 已关闭但残留的 NSWindow），
    /// 只按「同标题标签按钮数 − 同标题可见 AX 窗口数」放行，多出来的按 z 序丢弃。
    static func filterHiddenByTabs(_ wins: [WindowInfo], axWindowIDs: Set<CGWindowID>,
                                   tabTitles: [String]) -> [WindowInfo] {
        var quota: [String: Int] = [:]
        for t in tabTitles { quota[t, default: 0] += 1 }
        for w in wins where axWindowIDs.contains(w.windowID) { quota[w.title, default: 0] -= 1 }
        return wins.filter { w in
            if axWindowIDs.contains(w.windowID) { return true }
            guard let q = quota[w.title], q > 0 else { return false }
            quota[w.title] = q - 1
            return true
        }
    }

    /// 按 App 分组纯逻辑（自测覆盖）：输入已按 MRU 排好的列表，输出同 pid 的窗口紧挨着，
    /// App 之间按各自首个（=最近使用）窗口的先后排。同 App 三个窗口不再被别的 App 穿插。
    static func groupByApp(_ ordered: [WindowInfo]) -> [WindowInfo] {
        var order: [pid_t] = []
        var buckets: [pid_t: [WindowInfo]] = [:]
        for w in ordered {
            if buckets[w.pid] == nil { order.append(w.pid) }
            buckets[w.pid, default: []].append(w)
        }
        return order.flatMap { buckets[$0]! }
    }

    /// 默认选中纯逻辑（自测覆盖）：分组后「上一个用过的窗口」（MRU 序第二个）落在哪个下标就选哪个，
    /// 保住一按 OK 即回切；找不到退回 1（列表 ≥2）或 0。
    static func defaultSelection(grouped: [WindowInfo], mruOrdered: [WindowInfo]) -> Int {
        guard grouped.count > 1 else { return 0 }
        if mruOrdered.count > 1, let i = grouped.firstIndex(where: { $0.windowID == mruOrdered[1].windowID }) {
            return i
        }
        return 1
    }

    /// MRU 排序纯逻辑（自测覆盖）：在 `mru`（最新在前）里出现的窗口按其次序排前，
    /// 其余保持原（z 序）相对顺序接在后面。
    static func orderByMRU(_ wins: [WindowInfo], mru: [CGWindowID]) -> [WindowInfo] {
        var rank: [CGWindowID: Int] = [:]
        for (i, id) in mru.enumerated() where rank[id] == nil { rank[id] = i }
        let indexed = wins.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { a, b in
            switch (rank[a.1.windowID], rank[b.1.windowID]) {
            case let (ra?, rb?): return ra < rb
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0 < b.0
            }
        }.map { $0.1 }
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

    /// 当前桌面上的可见窗口（layer 0，z 序前到后 ≈ MRU）。
    static func visibleWindows() -> [WindowInfo] {
        windows(options: visibleListOptions)
    }

    /// 当前用户会话的全部普通 App 窗口，包括其他 Space/桌面和最小化窗口。
    /// `.optionAll` 会返回很多 0×0 helper/menu-bar 表面，因此统一做尺寸和 App 类型过滤。
    static func allWindows() -> [WindowInfo] {
        windows(options: globalListOptions)
    }

    private static func windows(options: CGWindowListOption) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let myPid = getpid()
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  let wid = d[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = d[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular, !app.isTerminated else { return nil }
            return WindowInfo(pid: pid, windowID: wid,
                              title: d[kCGWindowName as String] as? String ?? "")
        }
    }

    // MARK: - 执行入口

    /// 窗口级 MRU 数据源（KeyMapperApp 启动时注入 `WindowMRU.snapshot`）；未注入时退回 z 序。
    nonisolated(unsafe) static var mruProvider: (() -> [CGWindowID])?

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
        let ordered = orderByMRU(allWindows(), mru: mruProvider?() ?? [])
        guard let target = pickGlobalTarget(ordered),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        activateApplication(app) { activeApp in
            raiseMatchingWindow(target, app: activeApp)
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
    /// - false：当前用户会话的所有 App 窗口，跨全部 Space/桌面。
    /// 返回 (条目, 默认选中下标)。条目按 App 分组、App 按最近使用排；默认选中=上一个用过的窗口。
    static func pickerEntries(currentAppOnly: Bool, frontPid: pid_t?) -> (entries: [PickerEntry], selected: Int) {
        let mruOrdered = orderByMRU(dropGhosts(allWindows()), mru: mruProvider?() ?? [])
            .filter { !currentAppOnly || $0.pid == frontPid }
        let grouped = groupByApp(mruOrdered)
        let entries: [PickerEntry] = grouped.compactMap { info in
            guard let app = NSRunningApplication(processIdentifier: info.pid) else { return nil }
            return PickerEntry(window: info,
                               appName: app.localizedName ?? "未知应用",
                               bundleID: app.bundleIdentifier)
        }
        let kept = entries.map(\.window)
        return (entries, defaultSelection(grouped: kept, mruOrdered: mruOrdered.filter { w in kept.contains { $0.windowID == w.windowID } }))
    }

    /// 按 App 过滤幽灵条目：只对「有 AX 列表之外窗口」的 App 才去查标签栏（AX 往返有成本）。
    static func dropGhosts(_ wins: [WindowInfo]) -> [WindowInfo] {
        var byPid: [pid_t: [WindowInfo]] = [:]
        var order: [pid_t] = []
        for w in wins {
            if byPid[w.pid] == nil { order.append(w.pid) }
            byPid[w.pid, default: []].append(w)
        }
        var keep = Set<CGWindowID>()
        for pid in order {
            let group = byPid[pid]!
            let axIDs = Set(axWindowIDs(pid: pid))
            if group.allSatisfy({ axIDs.contains($0.windowID) }) {
                group.forEach { keep.insert($0.windowID) }
                continue
            }
            let titles = tabButtons(pid: pid).map(\.title)
            filterHiddenByTabs(group, axWindowIDs: axIDs, tabTitles: titles).forEach { keep.insert($0.windowID) }
        }
        return wins.filter { keep.contains($0.windowID) }
    }

    /// App 当前暴露的 AX 窗口 ID 集合（其他 Space / 隐藏标签页不在内）。
    static func axWindowIDs(pid: pid_t) -> [CGWindowID] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return [] }
        return wins.compactMap(windowID(of:))
    }

    /// 激活指定窗口：app 前置 + 按标题 AXRaise 精确定位（复用全局切换的成熟逻辑）。
    static func activate(_ target: WindowInfo) {
        guard let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        activateApplication(app) { activeApp in
            raiseMatchingWindow(target, app: activeApp)
        }
    }

    /// 跨 App 激活统一入口。macOS 的协作式激活不保证一个后台 accessory App 直接
    /// 调用 target.activate() 能拿到焦点；NSWorkspace 会代表当前前台 App 完成交接。
    static func activateApplication(_ app: NSRunningApplication,
                                    completion: ((NSRunningApplication) -> Void)? = nil) {
        if app.isActive {
            completion?(app)
            return
        }
        guard let url = app.bundleURL else {
            _ = app.activate(options: [.activateAllWindows])
            completion?(app)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.allowsRunningApplicationSubstitution = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { running, error in
            DispatchQueue.main.async {
                let activated = running ?? app
                if error != nil {
                    _ = app.activate(options: [.activateAllWindows])
                }
                completion?(activated)
            }
        }
    }

    /// App 已前置后精确前置目标窗口，三级：
    ///   ① AX 窗口按 ID 命中 → 取消最小化 + AXRaise + 设主窗口/焦点；
    ///   ② 命不中（隐藏标签页）→ 按标题找标签按钮 AXPress；同名多个时逐个按并用焦点窗口 ID 核对；
    ///   ③ 标签也没有（其他 Space 的窗口，AX 不可见）→ SkyLight 按窗口 ID 置前（AltTab 同款，best-effort）。
    private static func raiseMatchingWindow(_ target: WindowInfo, app: NSRunningApplication) {
        if let w = axWindow(for: target, app: app) {
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return
        }
        let candidates = tabButtons(pid: app.processIdentifier)
            .filter { !target.title.isEmpty && $0.title == target.title }
            .map(\.element)
        if !candidates.isEmpty {
            pressTabs(candidates, target: target, pid: app.processIdentifier)
            return
        }
        SkyLightFocus.focus(pid: app.processIdentifier, windowID: target.windowID)
    }

    /// 逐个按同名标签，150ms 后核对焦点窗口 ID；全部不中则停在最后一个（标题一致已是最优解）。
    private static func pressTabs(_ tabs: [AXUIElement], target: WindowInfo, pid: pid_t) {
        guard let first = tabs.first else { return }
        AXUIElementPerformAction(first, kAXPressAction as CFString)
        guard tabs.count > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if focusedWindowID(pid: pid) == target.windowID { return }
            pressTabs(Array(tabs.dropFirst()), target: target, pid: pid)
        }
    }
}

/// SkyLight 私有接口：按 CGWindowID 把窗口置前并设为 key（AltTab `Window.focus()` 同款字节序列）。
/// 全部 dlsym 动态解析，符号缺失即静默不做——只作为 AX 完全不可见（其他 Space）时的兜底。
enum SkyLightFocus {
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFront = @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias PostRecord = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError

    private static let symbols: (GetPSN, SetFront, PostRecord)? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let app = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let g = dlsym(app, "GetProcessForPID"),
              let f = dlsym(sky, "_SLPSSetFrontProcessWithOptions"),
              let p = dlsym(sky, "SLPSPostEventRecordTo") else { return nil }
        return (unsafeBitCast(g, to: GetPSN.self), unsafeBitCast(f, to: SetFront.self),
                unsafeBitCast(p, to: PostRecord.self))
    }()

    static var available: Bool { symbols != nil }

    static func focus(pid: pid_t, windowID: CGWindowID) {
        guard let (getPSN, setFront, post) = symbols else { return }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return }
        _ = setFront(&psn, windowID, 0x200)   // kCPSUserGenerated
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xF8
        bytes[0x3a] = 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        bytes[0x08] = 0x01
        _ = post(&psn, bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, bytes)
    }
}

/// 私有 AX 符号：AX 窗口元素 → CGWindowID（AltTab / yabai 长期依赖，macOS 26 仍在）。
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
