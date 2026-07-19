import AppKit
import CoreGraphics
import Foundation
import os

/// 由遥控器打开的 Mission Control 是一个短暂系统态：期间方向键由 MiRemote
/// 接管用于切换桌面，Home/菜单再次短按退出；20 秒无操作后自动失效。
enum TransientSystemUI {
    private static let exitWindowNs: UInt64 = 20_000_000_000
    private static let missionControlDeadline = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func markMissionControlEntered(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        missionControlDeadline.withLock { $0 = nowNs &+ exitWindowNs }
    }

    static func isMissionControlActive(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        missionControlDeadline.withLock { deadline in
            guard deadline != 0, nowNs <= deadline else {
                deadline = 0
                return false
            }
            return true
        }
    }

    static func consumeMissionControlExit(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        missionControlDeadline.withLock { deadline in
            guard deadline != 0, nowNs <= deadline else {
                deadline = 0
                return false
            }
            deadline = 0
            return true
        }
    }

    static func clearMissionControlExit() {
        missionControlDeadline.withLock { $0 = 0 }
    }
}

/// 适合遥控器触发的 macOS 工作区动作。
///
/// 这里只使用系统公开的键盘快捷键和现有的 `FocusInput` 实现，不依赖私有
/// WindowServer API。组合键会显式发送修饰键的 down/up，避免 Command、Control
/// 等按键在遥控器快速连按或事件被打断时残留为“粘住”状态。
enum WorkspaceAction: String, CaseIterable, Sendable {
    // App 与窗口
    case nextApplication = "next_app"
    case previousApplication = "previous_app"
    case nextApplicationWindow = "next_app_window"
    case previousApplicationWindow = "previous_app_window"
    case nextGlobalWindow = "next_global_window"
    case previousGlobalWindow = "previous_global_window"

    // Mission Control / Space
    case spaceLeft = "space_left"
    case spaceRight = "space_right"
    case missionControl = "mission_control"
    case applicationExpose = "app_expose"
    case showDesktop = "show_desktop"

    // 当前窗口 / App
    case minimizeWindow = "minimize_window"
    case minimizeApplicationWindows = "minimize_app_windows"
    case closeWindow = "close_window"
    case toggleFullScreen = "toggle_full_screen"
    case hideApplication = "hide_app"
    case hideOtherApplications = "hide_other_apps"

    // 聚焦与系统入口
    case focusInput = "focus_input"
    case spotlight = "spotlight"
    case focusMenuBar = "focus_menu_bar"
    case focusDock = "focus_dock"
    case focusNextWindow = "focus_next_window"
    case focusPreviousWindow = "focus_previous_window"
    case focusToolbar = "focus_toolbar"
    case focusNextFloatingWindow = "focus_next_floating_window"
    case focusPreviousFloatingWindow = "focus_previous_floating_window"
    case focusStatusMenus = "focus_status_menus"
    case notificationCenter = "notification_center"
    case controlCenter = "control_center"
}

/// UI 可直接消费的动作元数据；与执行代码使用同一个动作集合，避免选择器和执行器漂移。
struct WorkspaceActionDescriptor: Equatable, Sendable {
    let action: WorkspaceAction
    let title: String
    let category: String
    let shortcut: String
}

/// 键盘组合键的纯数据表示，供动作选择 UI、配置迁移和 selfCheck 使用。
struct WorkspaceShortcut: Equatable, Sendable {
    let keyCode: CGKeyCode
    let modifiers: [WorkspaceModifier]
}

enum WorkspaceModifier: String, CaseIterable, Sendable {
    case command
    case shift
    case option
    case control
    case function

    fileprivate var keyCode: CGKeyCode {
        switch self {
        case .command: 55
        case .shift: 56
        case .option: 58
        case .control: 59
        case .function: 63
        }
    }

    fileprivate var flag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .shift: .maskShift
        case .option: .maskAlternate
        case .control: .maskControl
        case .function: .maskSecondaryFn
        }
    }
}

enum WorkspaceActions {
    /// 稳定动作名目录。ActionRunner 可把 `.system(name)` 先交给
    /// `WorkspaceActions.perform(named:)`；返回 false 时再走旧 system 分支。
    static let descriptors: [WorkspaceActionDescriptor] = [
        .init(action: .nextApplication, title: "下一个应用", category: "应用与窗口", shortcut: "⌘⇥"),
        .init(action: .previousApplication, title: "上一个应用", category: "应用与窗口", shortcut: "⇧⌘⇥"),
        .init(action: .nextApplicationWindow, title: "同应用下一个窗口", category: "应用与窗口", shortcut: "⌘`"),
        .init(action: .previousApplicationWindow, title: "同应用上一个窗口", category: "应用与窗口", shortcut: "⇧⌘`"),
        .init(action: .nextGlobalWindow, title: "全局下一个窗口", category: "应用与窗口", shortcut: "⌃F4"),
        .init(action: .previousGlobalWindow, title: "全局上一个窗口", category: "应用与窗口", shortcut: "⇧⌃F4"),

        .init(action: .spaceLeft, title: "左侧桌面空间", category: "桌面与空间", shortcut: "⌃←"),
        .init(action: .spaceRight, title: "右侧桌面空间", category: "桌面与空间", shortcut: "⌃→"),
        .init(action: .missionControl, title: "调度中心", category: "桌面与空间", shortcut: "⌃↑"),
        .init(action: .applicationExpose, title: "当前应用所有窗口", category: "桌面与空间", shortcut: "⌃↓"),
        .init(action: .showDesktop, title: "显示桌面", category: "桌面与空间", shortcut: "Fn F11"),

        .init(action: .minimizeWindow, title: "最小化当前窗口", category: "当前窗口", shortcut: "⌘M"),
        .init(action: .minimizeApplicationWindows, title: "最小化当前应用全部窗口", category: "当前窗口", shortcut: "⌥⌘M"),
        .init(action: .closeWindow, title: "关闭当前窗口", category: "当前窗口", shortcut: "⌘W"),
        .init(action: .toggleFullScreen, title: "进入或退出全屏", category: "当前窗口", shortcut: "⌃⌘F"),
        .init(action: .hideApplication, title: "隐藏当前应用", category: "当前窗口", shortcut: "⌘H"),
        .init(action: .hideOtherApplications, title: "隐藏其他应用", category: "当前窗口", shortcut: "⌥⌘H"),

        .init(action: .focusInput, title: "聚焦输入框", category: "聚焦与系统", shortcut: "智能定位"),
        .init(action: .spotlight, title: "聚焦搜索", category: "聚焦与系统", shortcut: "⌘Space"),
        .init(action: .focusMenuBar, title: "聚焦菜单栏", category: "聚焦与系统", shortcut: "⌃F2"),
        .init(action: .focusDock, title: "聚焦程序坞", category: "聚焦与系统", shortcut: "⌃F3"),
        .init(action: .focusNextWindow, title: "聚焦下一个窗口", category: "聚焦与系统", shortcut: "⌃F4"),
        .init(action: .focusPreviousWindow, title: "聚焦上一个窗口", category: "聚焦与系统", shortcut: "⇧⌃F4"),
        .init(action: .focusToolbar, title: "聚焦窗口工具栏", category: "聚焦与系统", shortcut: "⌃F5"),
        .init(action: .focusNextFloatingWindow, title: "聚焦下一个面板", category: "聚焦与系统", shortcut: "⌃F6"),
        .init(action: .focusPreviousFloatingWindow, title: "聚焦上一个面板", category: "聚焦与系统", shortcut: "⇧⌃F6"),
        .init(action: .focusStatusMenus, title: "聚焦状态菜单", category: "聚焦与系统", shortcut: "⌃F8"),
        .init(action: .notificationCenter, title: "通知中心", category: "聚焦与系统", shortcut: "Fn N"),
        .init(action: .controlCenter, title: "控制中心", category: "聚焦与系统", shortcut: "Fn C"),
    ]

    static let shortcuts: [WorkspaceAction: WorkspaceShortcut] = [
        .nextApplication: chord(48, [.command]),
        .previousApplication: chord(48, [.command, .shift]),
        .nextApplicationWindow: chord(50, [.command]),
        .previousApplicationWindow: chord(50, [.command, .shift]),
        .nextGlobalWindow: chord(118, [.control]),
        .previousGlobalWindow: chord(118, [.control, .shift]),

        .spaceLeft: chord(123, [.control]),
        .spaceRight: chord(124, [.control]),
        .missionControl: chord(126, [.control]),
        .applicationExpose: chord(125, [.control]),
        .minimizeWindow: chord(46, [.command]),
        .minimizeApplicationWindows: chord(46, [.command, .option]),
        .closeWindow: chord(13, [.command]),
        .toggleFullScreen: chord(3, [.command, .control]),
        .hideApplication: chord(4, [.command]),
        .hideOtherApplications: chord(4, [.command, .option]),

        .spotlight: chord(49, [.command]),
        .focusMenuBar: chord(120, [.control]),
        .focusDock: chord(99, [.control]),
        .focusNextWindow: chord(118, [.control]),
        .focusPreviousWindow: chord(118, [.control, .shift]),
        .focusToolbar: chord(96, [.control]),
        .focusNextFloatingWindow: chord(97, [.control]),
        .focusPreviousFloatingWindow: chord(97, [.control, .shift]),
        .focusStatusMenus: chord(100, [.control]),
        .notificationCenter: chord(45, [.function]),
        .controlCenter: chord(8, [.function]),
    ]

    static var actionNames: [String] { WorkspaceAction.allCases.map(\.rawValue) }

    /// 动作名入口，便于由现有 `.system(String)` 无损接入。
    @discardableResult
    static func perform(named name: String) -> Bool {
        guard let action = WorkspaceAction(rawValue: name) else { return false }
        perform(action)
        return true
    }

    static func perform(_ action: WorkspaceAction) {
        if action == .focusInput {
            FocusInput.perform()
            return
        }
        if action == .showDesktop {
            showDesktop()
            return
        }
        guard let shortcut = shortcuts[action] else { return }
        post(shortcut)
    }

    /// 纯逻辑自检，不发送任何系统事件。
    static func selfCheck() -> Bool {
        let actions = Set(WorkspaceAction.allCases.map(\.rawValue))
        let described = Set(descriptors.map { $0.action.rawValue })
        guard actions.count == WorkspaceAction.allCases.count,
              described == actions,
              descriptors.allSatisfy({ !$0.title.isEmpty && !$0.category.isEmpty && !$0.shortcut.isEmpty }),
              actionNames.allSatisfy({ !$0.isEmpty && $0 == $0.lowercased() }) else { return false }

        let shortcutActions = Set(shortcuts.keys)
        guard shortcutActions == Set(WorkspaceAction.allCases.filter {
            $0 != .focusInput && $0 != .showDesktop
        }) else { return false }
        return shortcuts.values.allSatisfy { shortcut in
            shortcut.modifiers.count == Set(shortcut.modifiers.map(\.rawValue)).count
        }
    }

    private static func chord(_ keyCode: CGKeyCode, _ modifiers: [WorkspaceModifier]) -> WorkspaceShortcut {
        WorkspaceShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    /// 合成 Fn+F11 受用户功能键设置与系统符号快捷键状态影响，实机可完全无响应。
    /// Mission Control 的公开系统 App 入口不依赖这些偏好；参数 1 直接执行显示桌面。
    private static func showDesktop() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Mission Control", "--args", "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("显示桌面系统入口启动失败，回退 Fn+F11：\(error.localizedDescription)")
            post(chord(103, [.function]))
        }
    }

    private static func post(_ shortcut: WorkspaceShortcut) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        var flags: CGEventFlags = []

        // 修饰键按下：flags 表示该帧发出后的状态。
        for modifier in shortcut.modifiers {
            flags.insert(modifier.flag)
            postKey(modifier.keyCode, down: true, flags: flags, source: source)
        }
        postKey(shortcut.keyCode, down: true, flags: flags, source: source)
        postKey(shortcut.keyCode, down: false, flags: flags, source: source)

        // 逆序释放，且释放帧不再携带刚释放的修饰位，确保系统状态归零。
        for modifier in shortcut.modifiers.reversed() {
            flags.remove(modifier.flag)
            postKey(modifier.keyCode, down: false, flags: flags, source: source)
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags,
                                source: CGEventSource) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
