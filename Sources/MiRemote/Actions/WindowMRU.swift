import AppKit
import ApplicationServices

/// 窗口级 MRU 栈（最新在前，[0]=当前聚焦窗口）。
///
/// 数据来源三路：① `NSWorkspace.didActivateApplication` 时取该 App 的 AX 聚焦窗口；
/// ② 每个普通 App 挂一个 `AXObserver`，监听 `kAXFocusedWindowChanged` / `kAXMainWindowChanged`
/// （App 内切窗口、点标签页等不产生 App 激活通知的场景）；③ 选择器/切换动作命中后显式 `touch`。
/// 全部在主线程维护（NSWorkspace 通知与 AXObserver 回调都投递到主 run loop），
/// `WindowSwitcher.mruProvider` 读快照。
///
/// AltTab 的 MRU 也是这一套；`CGWindowList` 的 z 序对其他 Space / 最小化窗口没有可靠次序，只做兜底。
final class WindowMRU {

    static let capacity = 50

    private(set) var stack: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let myPid = ProcessInfo.processInfo.processIdentifier

    // MARK: 纯逻辑（自测覆盖）

    static func push(_ stack: [CGWindowID], _ id: CGWindowID, cap: Int = capacity) -> [CGWindowID] {
        var next = stack.filter { $0 != id }
        next.insert(id, at: 0)
        if next.count > cap { next.removeLast(next.count - cap) }
        return next
    }

    /// 只保留仍存在的窗口 ID（选择器打开时用当前 CGWindowList 清理）。
    static func prune(_ stack: [CGWindowID], existing: Set<CGWindowID>) -> [CGWindowID] {
        stack.filter { existing.contains($0) }
    }

    static func selfCheck() -> Bool {
        push([], 1) == [1]
            && push([1, 2, 3], 2) == [2, 1, 3]
            && push([1, 2, 3], 4, cap: 3) == [4, 1, 2]
            && prune([5, 6, 7], existing: [7, 5]) == [5, 7]
    }

    // MARK: 运行时

    func touch(_ id: CGWindowID) { stack = Self.push(stack, id) }

    func pruneTo(existing: Set<CGWindowID>) { stack = Self.prune(stack, existing: existing) }

    func snapshot() -> [CGWindowID] { stack }

    /// 记录 App 当前聚焦窗口（App 激活时调用）。
    func noteFocusedWindow(of app: NSRunningApplication) {
        guard app.processIdentifier != myPid,
              let id = WindowSwitcher.focusedWindowID(pid: app.processIdentifier) else { return }
        touch(id)
    }

    /// 开始跟踪：给所有在跑的普通 App 挂观察者，之后随启动/退出增删。主线程调用。
    func start() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
        if let front = NSWorkspace.shared.frontmostApplication { noteFocusedWindow(of: front) }
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                     object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            // 刚启动的 App 可能还没建 AX 树，稍后再挂
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.observe(app) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                     object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unobserve(app.processIdentifier)
        })
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        observers.keys.forEach(unobserve)
    }

    deinit { stop() }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != myPid, observers[pid] == nil, !app.isTerminated else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &observer) == .success, let observer else { return }
        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, axApp, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func unobserve(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// C 回调：element 即新聚焦/主窗口；拿不到 ID（无 AX 支持的 App）就忽略。
    private static let axCallback: AXObserverCallback = { _, element, _, refcon in
        guard let refcon, let id = WindowSwitcher.windowID(of: element) else { return }
        Unmanaged<WindowMRU>.fromOpaque(refcon).takeUnretainedValue().touch(id)
    }
}
