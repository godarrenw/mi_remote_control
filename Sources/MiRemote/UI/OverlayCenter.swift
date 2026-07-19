import AppKit
import SwiftUI

// M5 v2 浮层体系（DESIGN §3.1b「UI 模态路由」）：
//   窗口选择器（菜单键单击）/ 系统功能菜单（菜单键长按）/ 按键教程（Home 长按）
//   三个捕获式浮层：打开时 MappingEngine.setOverlayCapture 把遥控键喂给本中心；
//   App 控制模式 HUD（TV 单击进层 2 时展示）是非捕获的纯状态提示。
// 面板全部用 NSPanel(.nonactivatingPanel)：不抢焦点、不打断前台 App；
// 内容用系统材质与语义色，深浅色自动适配。

// MARK: - 系统功能菜单目录（静态数据 + 纯函数，供浮层与 self-test）

struct SystemMenuItem {
    let title: String
    let symbol: String
    let action: Action
}

enum SystemMenuCatalog {
    /// 网格条目（3 列）。全部走 ActionRunner 既有能力，无私有 API。
    static let items: [SystemMenuItem] = [
        .init(title: "调度中心",   symbol: "square.grid.3x2",             action: .system("mission_control")),
        .init(title: "App Exposé", symbol: "square.on.square",            action: .system("app_expose")),
        .init(title: "显示桌面",   symbol: "menubar.dock.rectangle",      action: .system("show_desktop")),
        .init(title: "左侧桌面",   symbol: "arrow.left.square",           action: .system("space_left")),
        .init(title: "右侧桌面",   symbol: "arrow.right.square",          action: .system("space_right")),
        .init(title: "聚焦输入框", symbol: "cursorarrow.and.square.on.square.dashed", action: .focusInput),
        .init(title: "播放 / 暂停", symbol: "playpause",                   action: .system("play_pause")),
        .init(title: "静音",       symbol: "speaker.slash",               action: .system("mute")),
        .init(title: "音量 ＋",    symbol: "speaker.wave.3",              action: .system("volume_up")),
        .init(title: "音量 －",    symbol: "speaker.wave.1",              action: .system("volume_down")),
        .init(title: "锁屏",       symbol: "lock",                        action: .system("lock_screen")),
        .init(title: "睡眠",       symbol: "moon.zzz",                    action: .system("display_sleep")),
    ]
    static let columns = 3

    /// 网格方向移动的纯逻辑（供 self-test）：行内左右回绕，上下按列移动并夹在边界。
    static func move(_ index: Int, key: RemoteKey, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        switch key {
        case .left:  return (index - 1 + count) % count
        case .right: return (index + 1) % count
        case .up:    return max(0, index - columns)
        case .down:  return min(count - 1, index + columns)
        default:     return index
        }
    }

    /// 浮层数据模型自测：条目非空、标题唯一、system 动作名全部在执行目录内。
    static func selfCheck() -> Bool {
        guard !items.isEmpty, Set(items.map(\.title)).count == items.count else { return false }
        let known = Set(WorkspaceActions.actionNames
                        + ["play_pause", "mute", "volume_up", "volume_down",
                           "lock_screen", "display_sleep", "mission_control"])
        for item in items {
            switch item.action {
            case .system(let name): if !known.contains(name) { return false }
            case .focusInput: break
            default: return false
            }
        }
        // 方向移动纯逻辑抽查（3 列 12 项）
        return move(0, key: .right, count: 12, columns: 3) == 1
            && move(0, key: .left, count: 12, columns: 3) == 11
            && move(1, key: .down, count: 12, columns: 3) == 4
            && move(1, key: .up, count: 12, columns: 3) == 0
            && move(10, key: .down, count: 12, columns: 3) == 11
    }
}

// MARK: - 浮层中心

@MainActor
final class OverlayCenter {

    enum Kind: String {
        case windowPicker = "window_picker"
        case systemMenu = "system_menu"
        case tutorial = "tutorial"
    }

    private weak var model: AppModel?
    private weak var services: AppServices?
    private let runner = ActionRunner()
    private let quickLook: MappingQuickLookController

    private var active: Kind?
    private var panel: NSPanel?
    private var escMonitor: Any?

    // 窗口选择器状态
    private var pickerEntries: [WindowSwitcher.PickerEntry] = []
    private var pickerIndex = 0
    private var pickerCurrentAppOnly = true
    // 系统功能菜单状态
    private var menuIndex = 0
    // App 控制模式 HUD
    private var hudPanel: NSPanel?

    init(model: AppModel, services: AppServices?) {
        self.model = model
        self.services = services
        self.quickLook = MappingQuickLookController(model: model)
    }

    private var engine: MappingEngine? { services?.keyMapper?.engine }
    private var frontApp: NSRunningApplication? { services?.keyMapper?.lastExternalApplication }

    // MARK: 打开 / 关闭

    /// ActionRunner.onOverlay 入口（主线程）。同名浮层已开 → 关闭（同键 toggle 兜底；
    /// 正常路径下浮层打开后按键已被捕获，走 handleKey 关闭）。
    func open(_ name: String) {
        guard let kind = Kind(rawValue: name) else {
            log("未知浮层名: \(name)")
            return
        }
        if active == kind { close(); return }
        if active != nil { close() }
        active = kind
        switch kind {
        case .windowPicker:
            pickerCurrentAppOnly = true
            reloadPickerEntries()
            showPanel(content: AnyView(windowPickerView()))
        case .systemMenu:
            menuIndex = 0
            showPanel(content: AnyView(systemMenuView()))
        case .tutorial:
            quickLook.setVisible(true,
                                 bundleID: frontApp?.bundleIdentifier,
                                 appName: frontApp?.localizedName)
        }
        installEscMonitor()
        // 捕获遥控键：浮层期间事件不走动作分发（引擎 mainDispatch 保证主线程回调）。
        engine?.setOverlayCapture { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
        }
    }

    func close() {
        guard active != nil else { return }
        active = nil
        engine?.setOverlayCapture(nil)
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        quickLook.setVisible(false, bundleID: nil, appName: nil)
    }

    /// 真键盘 Esc 关闭（浮层不抢焦点，收不到 keyDown，用全局监听兜底；需输入监控权限，已具备）。
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard ev.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.close() }
        }
    }

    // MARK: 遥控键路由（uiCapture 捕获回调，主线程）

    private func handleKey(_ event: ButtonEvent) {
        guard event.isDown, let active else { return }
        switch active {
        case .windowPicker: handlePickerKey(event.key)
        case .systemMenu:   handleMenuKey(event.key)
        case .tutorial:
            // 再按 Home / 返回 / OK 关闭；其余键吞掉（教程页不该有副作用）。
            if event.key == .home || event.key == .back || event.key == .ok { close() }
        }
    }

    private func handlePickerKey(_ key: RemoteKey) {
        switch key {
        case .left:
            guard !pickerEntries.isEmpty else { return }
            pickerIndex = (pickerIndex - 1 + pickerEntries.count) % pickerEntries.count
            refreshPanel(content: AnyView(windowPickerView()))
        case .right:
            guard !pickerEntries.isEmpty else { return }
            pickerIndex = (pickerIndex + 1) % pickerEntries.count
            refreshPanel(content: AnyView(windowPickerView()))
        case .menu, .up, .down:
            // 再按菜单键（或上下）= 范围切换：当前 App ↔ 所有 App
            pickerCurrentAppOnly.toggle()
            reloadPickerEntries()
            refreshPanel(content: AnyView(windowPickerView()))
        case .ok:
            if pickerEntries.indices.contains(pickerIndex) {
                let target = pickerEntries[pickerIndex].window
                close()
                WindowSwitcher.activate(target)
            } else {
                close()
            }
        case .back, .home:
            close()
        default:
            break
        }
    }

    private func handleMenuKey(_ key: RemoteKey) {
        switch key {
        case .up, .down, .left, .right:
            menuIndex = SystemMenuCatalog.move(menuIndex, key: key,
                                               count: SystemMenuCatalog.items.count,
                                               columns: SystemMenuCatalog.columns)
            refreshPanel(content: AnyView(systemMenuView()))
        case .ok:
            let item = SystemMenuCatalog.items[menuIndex]
            close()
            // 先关浮层再执行：目标动作（如聚焦输入框）需要落在真实前台 App 上。
            runner.run(item.action)
        case .back, .menu, .home:
            close()
        default:
            break
        }
    }

    private func reloadPickerEntries() {
        pickerEntries = WindowSwitcher.pickerEntries(currentAppOnly: pickerCurrentAppOnly,
                                                     frontPid: frontApp?.processIdentifier)
        pickerIndex = 0
    }

    // MARK: 面板

    /// 全屏透明面板承载居中内容：不抢焦点；点空白（内容之外任意处）关闭。
    private func showPanel(content: AnyView) {
        let p = NSPanel(contentRect: NSScreen.main?.frame ?? .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
        refreshPanel(content: content)
        p.orderFrontRegardless()
    }

    private func refreshPanel(content: AnyView) {
        guard let panel else { return }
        let root = OverlayBackdrop(onDismiss: { [weak self] in self?.close() }) { content }
        panel.contentView = NSHostingView(rootView: root)
        if let screen = NSScreen.main { panel.setFrame(screen.frame, display: true) }
    }

    // MARK: SwiftUI 内容

    private func windowPickerView() -> some View {
        WindowPickerView(entries: pickerEntries,
                         selected: pickerIndex,
                         currentAppOnly: pickerCurrentAppOnly,
                         frontAppName: frontApp?.localizedName)
    }

    private func systemMenuView() -> some View {
        SystemMenuView(selected: menuIndex)
    }

    // MARK: App 控制模式 HUD（层 2；非捕获，仅提示）

    /// 层变化钩子（GUIAppDelegate 接线）。进层 2 → 弹角落 HUD 列出当前 App 模式键位；
    /// 回层 0 或进入其他层 → 收起。音效由 AppModel.noteLayer（可选提示音）负责。
    func noteLayer(_ layer: Int) {
        guard layer == 2 else {
            hudPanel?.orderOut(nil)
            return
        }
        guard let model else { return }
        let bundleID = frontApp?.bundleIdentifier ?? "global"
        let rows = Self.controlModeRows(config: model.config, profile: bundleID)
        let view = ControlModeHUDView(appName: frontApp?.localizedName ?? "当前 App", rows: rows)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        if hudPanel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            hudPanel = p
        }
        guard let hudPanel else { return }
        hudPanel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            hudPanel.setFrame(NSRect(x: f.maxX - size.width - 24, y: f.maxY - size.height - 24,
                                     width: size.width, height: size.height), display: true)
        }
        hudPanel.orderFrontRegardless()
    }

    /// 当前 App 控制模式（层2）键位表：实际生效绑定（global+overlay 合并）。纯函数可测。
    nonisolated static func controlModeRows(config: MappingConfig, profile: String) -> [(String, String)] {
        let order: [RemoteKey] = [.ok, .back, .up, .down, .left, .right,
                                  .volUp, .volDown, .menu, .home, .power]
        var rows: [(String, String)] = []
        for key in order {
            guard let binding = MappingDetailResolver.binding(in: config, profile: profile, key: key),
                  let action = binding.layers?["2"] else { continue }
            rows.append((KeyDisplay.badge(key), ActionSummary.describe(action)))
        }
        rows.append(("TV", "退出控制模式"))
        return rows
    }

    private func log(_ msg: String) { NSLog("[OverlayCenter] %@", msg) }
}

// MARK: - 视图

/// 全屏点空白关闭的背景 + 居中内容。
private struct OverlayBackdrop<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 窗口选择器：横向卡片（App 图标 + 窗口标题），系统蓝描边高亮所选。
private struct WindowPickerView: View {
    let entries: [WindowSwitcher.PickerEntry]
    let selected: Int
    let currentAppOnly: Bool
    let frontAppName: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                Text(currentAppOnly ? "窗口 · \(frontAppName ?? "当前 App")" : "窗口 · 所有 App")
                    .font(.headline)
                Spacer()
                Text("←→ 选择 · 菜单键切范围 · OK 前往 · 返回关闭")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                Text(currentAppOnly ? "当前 App 没有可见窗口，按菜单键查看所有 App"
                                    : "没有可见窗口")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 30)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                                card(entry, isSelected: index == selected).id(index)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                    }
                    .onAppear { proxy.scrollTo(selected, anchor: .center) }
                    .onChange(of: selected) { _, value in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(value, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private func card(_ entry: WindowSwitcher.PickerEntry, isSelected: Bool) -> some View {
        VStack(spacing: 8) {
            appIcon(entry.bundleID)
                .frame(width: 44, height: 44)
            Text(entry.window.title.isEmpty ? entry.appName : entry.window.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120)
            Text(entry.appName)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 1 : 0.55),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
        .shadow(color: isSelected ? Color.accentColor.opacity(0.5) : .clear, radius: 5)
    }

    @ViewBuilder private func appIcon(_ bundleID: String?) -> some View {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary)
        }
    }
}

/// 系统功能菜单：3 列网格，方向键选择、OK 执行。
private struct SystemMenuView: View {
    let selected: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "square.grid.3x3")
                Text("系统功能").font(.headline)
                Spacer()
                Text("方向选择 · OK 执行 · 返回关闭")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let columns = Array(repeating: GridItem(.fixed(132), spacing: 10),
                                count: SystemMenuCatalog.columns)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(SystemMenuCatalog.items.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 20))
                        Text(item.title).font(.caption)
                    }
                    .frame(width: 124, height: 62)
                    .background(Color(nsColor: .controlBackgroundColor)
                        .opacity(index == selected ? 1 : 0.55),
                        in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(index == selected ? Color.accentColor : .clear, lineWidth: 2.5))
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }
}

/// App 控制模式角落 HUD：列出模式内键位含义（非捕获，可点穿）。
private struct ControlModeHUDView: View {
    let appName: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.accentColor)
                Text("App 控制模式 · \(appName)")
                    .font(.system(size: 12, weight: .semibold))
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 38, height: 18)
                        .background(Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 5))
                    Text(row.1).font(.system(size: 11)).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
