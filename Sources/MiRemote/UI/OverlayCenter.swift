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
    /// 危险动作（锁屏/睡眠/退出 App）：OK 需按住 0.6s 填充确认，杜绝单手误触（gamepad-ux D2）。
    var dangerous: Bool = false
}

enum SystemMenuCatalog {
    /// 网格条目（3 列）。全部走 ActionRunner 既有能力，无私有 API；危险项标红并集中排在末尾。
    static let items: [SystemMenuItem] = [
        .init(title: "调度中心",   symbol: "square.grid.3x2",             action: .system("mission_control")),
        .init(title: "App Exposé", symbol: "square.on.square",            action: .system("app_expose")),
        .init(title: "显示桌面",   symbol: "menubar.dock.rectangle",      action: .system("show_desktop")),
        .init(title: "左侧桌面",   symbol: "arrow.left.square",           action: .system("space_left")),
        .init(title: "右侧桌面",   symbol: "arrow.right.square",          action: .system("space_right")),
        .init(title: "聚焦编辑区", symbol: "cursorarrow.and.square.on.square.dashed", action: .focusInput),
        .init(title: "播放 / 暂停", symbol: "playpause",                   action: .system("play_pause")),
        .init(title: "静音",       symbol: "speaker.slash",               action: .system("mute")),
        .init(title: "打开 MiRemote 设置", symbol: "gearshape",           action: .overlay("open_settings")),
        .init(title: "退出当前 App", symbol: "escape",                    action: .keyStroke(key: "q", mods: ["left_cmd"]), dangerous: true),
        .init(title: "锁屏",       symbol: "lock",                        action: .system("lock_screen"), dangerous: true),
        .init(title: "睡眠",       symbol: "moon.zzz",                    action: .system("display_sleep"), dangerous: true),
    ]
    /// 常规区列数：9 个常规项 = 3×3；3 个危险项独立一行。
    static let columns = 3
    /// 危险项 OK 按住确认时长（gamepad-ux D2 遥控场景甜点值）。
    static let confirmHoldSeconds: TimeInterval = 0.6
    /// 行宽布局：常规网格 + 末行危险区。
    static var rowWidths: [Int] {
        let regular = items.filter { !$0.dangerous }.count
        var rows = Array(repeating: columns, count: regular / columns)
        if regular % columns != 0 { rows.append(regular % columns) }
        let dangerous = items.filter(\.dangerous).count
        if dangerous > 0 { rows.append(dangerous) }
        return rows
    }

    /// index → (行, 列)（按 rowWidths 切分）。
    static func position(of index: Int, rows: [Int]) -> (row: Int, col: Int) {
        var rest = index
        for (r, width) in rows.enumerated() {
            if rest < width { return (r, rest) }
            rest -= width
        }
        return (max(0, rows.count - 1), 0)
    }

    /// 网格方向移动的纯逻辑（供 self-test）：左右全序回绕，上下跨行保列并夹在行宽内。
    static func move(_ index: Int, key: RemoteKey, rows: [Int]) -> Int {
        let count = rows.reduce(0, +)
        guard count > 0 else { return 0 }
        switch key {
        case .left:  return (index - 1 + count) % count
        case .right: return (index + 1) % count
        case .up, .down:
            let (row, col) = position(of: index, rows: rows)
            let target = key == .up ? max(0, row - 1) : min(rows.count - 1, row + 1)
            guard target != row else { return index }
            let prefix = rows.prefix(target).reduce(0, +)
            return prefix + min(col, rows[target] - 1)
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
            case .keyStroke: break   // 退出当前 App = ⌘Q
            case .overlay(let name): if name != "open_settings" { return false }
            default: return false
            }
        }
        // 实体音量 +/- 已是全局快捷键，系统菜单不再重复；保留无实体键的静音。
        let systemNames = items.compactMap { item -> String? in
            if case .system(let name) = item.action { return name }
            return nil
        }
        guard systemNames.contains("mute"),
              !systemNames.contains("volume_up"), !systemNames.contains("volume_down") else { return false }
        // 危险项必须集中在末尾且要求按住确认；常规区必须刚好铺满整行（无孤行）
        let dangerousIdx = items.enumerated().filter { $0.element.dangerous }.map(\.offset)
        guard dangerousIdx == Array((items.count - dangerousIdx.count)..<items.count) else { return false }
        guard (items.count - dangerousIdx.count) % columns == 0 else { return false }
        // 方向移动纯逻辑抽查（行宽 [3,3,3,3] 共 12 项）
        let rows = rowWidths
        return move(0, key: .right, rows: rows) == 1
            && move(0, key: .left, rows: rows) == 11
            && move(1, key: .down, rows: rows) == 4
            && move(4, key: .down, rows: rows) == 7
            && move(8, key: .down, rows: rows) == 11
            && move(11, key: .up, rows: rows) == 8
            && move(1, key: .up, rows: rows) == 1
    }
}

// MARK: - 浮层视图状态（持久 HostingView 的唯一数据源）

/// 选中移动 = @Published 变化驱动的连续动画；视图树只在浮层打开时创建一次，不随按键重建。
@MainActor
final class OverlayUIState: ObservableObject {
    @Published var kind: OverlayCenter.Kind?
    @Published var pickerEntries: [WindowSwitcher.PickerEntry] = []
    @Published var pickerIndex = 0
    @Published var pickerCurrentAppOnly = false
    @Published var frontAppName: String?
    @Published var menuIndex = 0
    @Published var menuConfirming = false
    @Published var wheelEntries: [AppWheelView.Entry] = []
    @Published var wheelIndex = 0
}

/// 窗口选择器的菜单键三段流程：全局跨桌面 → 当前 App → 关闭。
enum WindowPickerFlow {
    /// true=当前 App，false=全局，nil=关闭。
    static func nextAfterMenu(currentAppOnly: Bool) -> Bool? {
        currentAppOnly ? nil : true
    }
}

// MARK: - 浮层中心

@MainActor
final class OverlayCenter {

    enum Kind: String {
        case windowPicker = "window_picker"
        case systemMenu = "system_menu"
        case tutorial = "tutorial"
        case appWheel = "app_wheel"
    }

    private weak var model: AppModel?
    private weak var services: AppServices?
    private let runner = ActionRunner()
    private let quickLook: MappingQuickLookController

    private var active: Kind?
    private var panel: NSPanel?
    private let uiState = OverlayUIState()
    private var escMonitor: Any?

    // 窗口选择器状态
    private var pickerEntries: [WindowSwitcher.PickerEntry] = []
    private var pickerIndex = 0
    private var pickerCurrentAppOnly = false
    // 系统功能菜单状态
    private var menuIndex = 0
    // App 轮盘状态（停留式，DESIGN §3.1b：TV 长按弹出后松手停留，3s 无操作自动关）
    private var wheelApps: [NSRunningApplication] = []
    private var wheelIndex = 0
    private var wheelIdleTimer: Timer?
    /// 窗口选择/系统菜单/教程不应无限占用遥控路由；10s 无操作自动收起。
    private static let overlayIdleSeconds: TimeInterval = 10
    private var overlayIdleTimer: Timer?
    // App 控制模式 HUD
    private var hudPanel: NSPanel?
    // 按键提示条（gamepad-ux B1：模式/浮层激活时屏底常驻）
    private var hintPanel: NSPanel?
    // 列表导航按住加速（gamepad-ux D3）：400ms 起连发，1.5s 后提速
    private var repeatKey: RemoteKey?
    private var repeatTimer: Timer?
    // 危险动作 hold-to-confirm（gamepad-ux D2）
    private var confirmTimer: Timer?
    private var confirmingIndex: Int?

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
    /// 「打开 MiRemote 设置」可绑定动作（菜单栏优先形态的遥控入口，GUIAppDelegate 接线）。
    var onOpenSettings: (() -> Void)?

    func open(_ name: String) {
        if name == "open_settings" {
            close()
            onOpenSettings?()
            return
        }
        guard let kind = Kind(rawValue: name) else {
            log("未知浮层名: \(name)")
            return
        }
        if active == kind { close(); return }
        if active != nil { close() }
        active = kind
        switch kind {
        case .windowPicker:
            pickerCurrentAppOnly = false
            reloadPickerEntries()
            showPanel()
        case .systemMenu:
            menuIndex = 0
            showPanel()
        case .tutorial:
            quickLook.setVisible(true,
                                 bundleID: frontApp?.bundleIdentifier,
                                 appName: frontApp?.localizedName)
        case .appWheel:
            // 数据源 = KeyMapperApp 的 MRU 栈（[0]=当前前台，[1..]=最近用过，主线程读）
            wheelApps = services?.keyMapper?.mruExternalApplications.filter { !$0.isTerminated } ?? []
            wheelIndex = wheelApps.count > 1 ? 1 : 0   // 默认选「上一个 App」，一确认即回切
            showPanel()
            restartWheelIdleTimer()
        }
        if kind != .appWheel { restartOverlayIdleTimer() }
        installEscMonitor()
        showHintBar(HintBarCatalog.hints(for: kind))
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
        wheelIdleTimer?.invalidate()
        wheelIdleTimer = nil
        overlayIdleTimer?.invalidate()
        overlayIdleTimer = nil
        stopRepeat()
        cancelConfirm(refresh: false)
        // 消失过渡：SwiftUI 侧 kind→nil 驱动缩放淡出，动画结束后仅 orderOut（面板常驻不销毁）
        withAnimation(Motion.overlay) { uiState.kind = nil }
        let closing = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.fadeOutDuration) { [weak self] in
            guard self?.active == nil else { return }   // 淡出期间又打开了新浮层则不收
            closing?.orderOut(nil)
        }
        quickLook.setVisible(false, bundleID: nil, appName: nil)
        // 若仍处于某个层，提示条回落为该层键表；否则收起
        if let model, model.activeLayer != 0 {
            showHintBar(HintBarCatalog.hints(forLayer: model.activeLayer,
                                             config: model.config,
                                             profile: frontApp?.bundleIdentifier ?? "global"))
        } else {
            hideHintBar()
        }
    }

    /// 逃生键（长按菜单 1.5s）触发：关闭所有浮层与 HUD。层态由引擎自清，
    /// 菜单栏/角标随 onLayerChanged 回到全局态。
    func escapeHatch() {
        close()
        noteLayer(0)
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
        guard let active else { return }
        if active == .appWheel {
            restartWheelIdleTimer()
        } else {
            restartOverlayIdleTimer()
        }
        guard event.isDown else {
            keyUp(event.key)
            return
        }
        switch active {
        case .windowPicker: handlePickerKey(event.key)
        case .systemMenu:   handleMenuKey(event.key)
        case .appWheel:     handleWheelKey(event.key)
        case .tutorial:
            // 再按 Home / 返回 / OK 关闭；其余键吞掉（教程页不该有副作用）。
            if event.key == .home || event.key == .back || event.key == .ok { close() }
        }
    }

    /// 松键：结束按住连发；OK 松开撤销危险动作确认（gamepad-ux D2/D3）。
    private func keyUp(_ key: RemoteKey) {
        if repeatKey == key { stopRepeat() }
        if key == .ok, confirmingIndex != nil { cancelConfirm(refresh: true) }
    }

    // MARK: 按住加速（gamepad-ux D3：立即 1 步 → 400ms 起 130ms/步 → 1.5s 后 65ms/步）

    private func startRepeat(_ key: RemoteKey, step: @escaping @MainActor () -> Void) {
        stopRepeat()
        repeatKey = key
        let startedAt = Date()
        let t = Timer(timeInterval: 0.13, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.repeatKey == key, self.active != nil else {
                    timer.invalidate()
                    return
                }
                step()
                if Date().timeIntervalSince(startedAt) > 1.5 { step() }   // 提速一倍
            }
        }
        t.fireDate = Date().addingTimeInterval(0.4)   // initial delay 防误连发
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatKey = nil
    }

    private func pickerStep(_ delta: Int) {
        guard !pickerEntries.isEmpty else { return }
        pickerIndex = (pickerIndex + delta + pickerEntries.count) % pickerEntries.count
        sync()
    }

    private func handlePickerKey(_ key: RemoteKey) {
        switch key {
        case .left:
            pickerStep(-1)
            startRepeat(key) { [weak self] in self?.pickerStep(-1) }
        case .right:
            pickerStep(1)
            startRepeat(key) { [weak self] in self?.pickerStep(1) }
        case .menu:
            // 菜单键固定三段：第一下已打开“全局跨桌面”；
            // 第二下切“当前 App”；第三下关闭。
            guard let next = WindowPickerFlow.nextAfterMenu(currentAppOnly: pickerCurrentAppOnly) else {
                close()
                return
            }
            pickerCurrentAppOnly = next
            reloadPickerEntries()
            sync()
        case .up, .down:
            // 上下保留为快速往返查看两个范围，不影响菜单键三段语义。
            pickerCurrentAppOnly.toggle()
            reloadPickerEntries()
            sync()
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

    private func menuStep(_ key: RemoteKey) {
        menuIndex = SystemMenuCatalog.move(menuIndex, key: key, rows: SystemMenuCatalog.rowWidths)
        sync()
    }

    private func handleMenuKey(_ key: RemoteKey) {
        switch key {
        case .up, .down, .left, .right:
            cancelConfirm(refresh: false)
            menuStep(key)
            startRepeat(key) { [weak self] in self?.menuStep(key) }
        case .ok:
            let item = SystemMenuCatalog.items[menuIndex]
            if item.dangerous {
                beginConfirm(item: item)
            } else {
                close()
                // 先关浮层再执行：目标动作（如聚焦输入框）需要落在真实前台 App 上。
                runner.run(item.action)
            }
        case .back, .menu, .home:
            close()
        default:
            break
        }
    }

    // MARK: 危险动作 hold-to-confirm（OK 按住 0.6s 填充环，中途松开取消）

    private func beginConfirm(item: SystemMenuItem) {
        guard confirmingIndex == nil else { return }
        confirmingIndex = menuIndex
        let index = menuIndex
        sync()
        let t = Timer(timeInterval: SystemMenuCatalog.confirmHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.confirmingIndex == index else { return }
                self.confirmingIndex = nil
                self.close()
                self.runner.run(SystemMenuCatalog.items[index].action)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        confirmTimer = t
    }

    private func cancelConfirm(refresh: Bool) {
        confirmTimer?.invalidate()
        confirmTimer = nil
        guard confirmingIndex != nil else { return }
        confirmingIndex = nil
        if refresh, active == .systemMenu { sync() }
    }

    /// App 轮盘（停留式）：方向环选 App、OK 或再按 TV 确认切换、返回取消，
    /// 每次按键重置 3s 无操作自动关闭计时。
    private func handleWheelKey(_ key: RemoteKey) {
        restartWheelIdleTimer()
        switch key {
        case .left, .up:
            guard !wheelApps.isEmpty else { return }
            wheelIndex = (wheelIndex - 1 + wheelApps.count) % wheelApps.count
            sync()
        case .right, .down:
            guard !wheelApps.isEmpty else { return }
            wheelIndex = (wheelIndex + 1) % wheelApps.count
            sync()
        case .ok, .tv:
            let target = wheelApps.indices.contains(wheelIndex) ? wheelApps[wheelIndex] : nil
            close()
            if let target { WindowSwitcher.activateApplication(target) }
        case .back, .home, .menu:
            close()
        default:
            break
        }
    }

    private func restartWheelIdleTimer() {
        wheelIdleTimer?.invalidate()
        wheelIdleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func restartOverlayIdleTimer() {
        overlayIdleTimer?.invalidate()
        overlayIdleTimer = Timer.scheduledTimer(withTimeInterval: Self.overlayIdleSeconds,
                                                repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func reloadPickerEntries() {
        pickerEntries = WindowSwitcher.pickerEntries(currentAppOnly: pickerCurrentAppOnly,
                                                     frontPid: frontApp?.processIdentifier)
        pickerIndex = 0
    }

    // MARK: 面板（持久 HostingView：视图树只建一次，之后全部走 sync() 状态驱动）

    /// 把逻辑状态发布给持久视图树；选中类变化以 Motion.select 驱动连续过渡（Codex 评审 P2-1）。
    private func sync(animated: Bool = true) {
        let apply = { [self] in
            uiState.kind = active
            uiState.pickerEntries = pickerEntries
            uiState.pickerIndex = pickerIndex
            uiState.pickerCurrentAppOnly = pickerCurrentAppOnly
            uiState.frontAppName = frontApp?.localizedName
            uiState.menuIndex = menuIndex
            uiState.menuConfirming = confirmingIndex != nil
            uiState.wheelEntries = wheelApps.map {
                AppWheelView.Entry(name: $0.localizedName ?? $0.bundleIdentifier ?? "App",
                                   bundleID: $0.bundleIdentifier)
            }
            uiState.wheelIndex = wheelIndex
        }
        if animated {
            withAnimation(Motion.select) { apply() }
        } else {
            apply()
        }
    }

    /// 常驻面板：NSPanel 与 NSHostingView 全生命周期只创建一次；
    /// show/hide 仅切换 orderFront/orderOut，显隐与入退场动画全部由 uiState.kind 驱动，
    /// 跨次打开视图树连续（Codex r3 P1：不再是"单次打开期间"的伪持久）。
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSScreen.main?.frame ?? .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: OverlayRootView(state: uiState,
                                                                onDismiss: { [weak self] in self?.close() }))
        panel = p
        return p
    }

    /// 全屏透明面板承载居中内容：不抢焦点；点空白（内容之外任意处）关闭。
    private func showPanel() {
        let p = ensurePanel()
        if let screen = NSScreen.main { p.setFrame(screen.frame, display: true) }
        uiState.kind = nil       // 入场从隐藏态开始（消失后残留的 kind 已在 close 清空，这里兜底）
        sync(animated: false)    // 数据先无动画就位
        uiState.kind = nil
        p.orderFrontRegardless()
        withAnimation(Motion.overlay) { uiState.kind = active }
    }

    // MARK: App 控制模式 HUD（层 2；非捕获，仅提示）

    /// 层变化钩子（GUIAppDelegate 接线）。进层 2 → 弹角落 HUD 列出当前 App 模式键位；
    /// 回层 0 或进入其他层 → 收起。音效由 AppModel.noteLayer（可选提示音）负责。
    func noteLayer(_ layer: Int) {
        // 按键提示条：层激活时显示该层键表（浮层打开期间由浮层键表接管，不在此覆盖）
        if active == nil {
            if layer != 0, let model {
                showHintBar(HintBarCatalog.hints(forLayer: layer, config: model.config,
                                                 profile: frontApp?.bundleIdentifier ?? "global"))
            } else {
                hideHintBar()
            }
        }
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

    // MARK: 按键提示条面板（屏底半透明横条，可点穿；通用页可关，默认开）

    private func showHintBar(_ items: [HintBarCatalog.Hint]) {
        guard model?.showHintBar != false, !items.isEmpty else {
            hideHintBar()
            return
        }
        let host = NSHostingView(rootView: HintBarView(items: items))
        host.frame.size = host.fittingSize
        if hintPanel == nil {
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
            hintPanel = p
        }
        guard let hintPanel else { return }
        hintPanel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            hintPanel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 16,
                                      width: size.width, height: size.height), display: true)
        }
        if !hintPanel.isVisible {
            hintPanel.alphaValue = 0
            hintPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fadeInDuration
                hintPanel.animator().alphaValue = 1
            }
        } else {
            hintPanel.orderFrontRegardless()
        }
    }

    private func hideHintBar() {
        guard let hintPanel, hintPanel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fadeOutDuration
            hintPanel.animator().alphaValue = 0
        }, completionHandler: {
            hintPanel.orderOut(nil)
            hintPanel.alphaValue = 1
        })
    }

    private func log(_ msg: String) { NSLog("[OverlayCenter] %@", msg) }
}

// MARK: - 按键提示条（gamepad-ux B1：PS5 glyph bar 范式）

enum HintBarCatalog {
    struct Hint {
        let keys: [RemoteKey]
        let text: String
    }

    /// 浮层键表（与各浮层 handleKey 路由保持一致）。
    static func hints(for kind: OverlayCenter.Kind) -> [Hint] {
        switch kind {
        case .windowPicker:
            return [Hint(keys: [.left, .right], text: "选窗（按住加速）"),
                    Hint(keys: [.menu], text: "全局 → 当前 → 关闭"),
                    Hint(keys: [.ok], text: "前往"),
                    Hint(keys: [.back], text: "关闭")]
        case .systemMenu:
            return [Hint(keys: [.up, .down, .left, .right], text: "选择"),
                    Hint(keys: [.ok], text: "执行 · 红色项按住"),
                    Hint(keys: [.back], text: "关闭")]
        case .appWheel:
            return [Hint(keys: [.up, .down, .left, .right], text: "选 App"),
                    Hint(keys: [.ok, .tv], text: "切换"),
                    Hint(keys: [.back], text: "取消")]
        case .tutorial:
            return [Hint(keys: [.home, .back, .ok], text: "关闭教程")]
        }
    }

    /// 层键表：该层每个键的绑定摘要（最多 5 条 + 退出提示），数据与 HUD 同源。
    static func hints(forLayer layer: Int, config: MappingConfig, profile: String) -> [Hint] {
        let order: [RemoteKey] = [.ok, .back, .up, .down, .left, .right, .volUp, .volDown, .menu, .home]
        var result: [Hint] = []
        for key in order {
            guard result.count < 5,
                  let binding = MappingDetailResolver.binding(in: config, profile: profile, key: key),
                  let action = binding.layers?["\(layer)"] else { continue }
            var text = ActionSummary.describe(action)
            if text.count > 10 { text = String(text.prefix(10)) + "…" }
            result.append(Hint(keys: [key], text: text))
        }
        if layer == 2 {
            result.append(Hint(keys: [.tv], text: "退出"))
        } else {
            result.append(Hint(keys: [], text: layer == 1 ? "松开 OK 退出" : "再触发一次退出"))
        }
        return result
    }
}

/// 单键小键帽字形（深底白符，复用 RemoteDiagram 的键面语言）。
struct KeyCapView: View {
    let key: RemoteKey

    private static let symbols: [RemoteKey: String] = [
        .up: "arrow.up", .down: "arrow.down", .left: "arrow.left", .right: "arrow.right",
        .back: "arrow.backward.to.line", .home: "house", .menu: "line.3.horizontal",
        .tv: "tv", .power: "power", .voice: "mic",
        .volUp: "plus", .volDown: "minus",
    ]

    var body: some View {
        Group {
            if let symbol = Self.symbols[key] {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            } else {
                Text(key == .ok ? "OK" : KeyDisplay.badge(key))
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12),
                    in: RoundedRectangle(cornerRadius: Radius.small))
    }
}

/// 屏底提示条：键帽字形 + 短词，随模式/浮层自动换文案。
struct HintBarView: View {
    let items: [HintBarCatalog.Hint]

    var body: some View {
        HStack(spacing: Spacing.rowH) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    ForEach(item.keys, id: \.self) { key in KeyCapView(key: key) }
                    Text(item.text).font(.callout)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - 视图

/// 持久根视图：观察 OverlayUIState，选中变化在既有视图树内做连续动画；
/// 入退场也由 kind 驱动（打开=spring 弹入，关闭=缩放淡出），视图树跨次打开不重建。
private struct OverlayRootView: View {
    @ObservedObject var state: OverlayUIState
    let onDismiss: () -> Void

    private var visible: Bool { state.kind != nil }

    var body: some View {
        ZStack {
            // 轻度压暗背景（主机浮层惯例）：突出浮层层级，点空白关闭
            Color.black.opacity(visible ? 0.18 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            Group {
                switch state.kind {
                case .windowPicker:
                    WindowPickerView(entries: state.pickerEntries,
                                     selected: state.pickerIndex,
                                     currentAppOnly: state.pickerCurrentAppOnly,
                                     frontAppName: state.frontAppName)
                case .systemMenu:
                    SystemMenuView(selected: state.menuIndex, confirming: state.menuConfirming)
                case .appWheel:
                    AppWheelView(apps: state.wheelEntries, selected: state.wheelIndex)
                default:
                    EmptyView()
                }
            }
            .scaleEffect(visible ? 1 : 0.96)
            .opacity(visible ? 1 : 0)
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
                Text(currentAppOnly ? "窗口 · \(frontAppName ?? "当前 App")"
                                    : "窗口 · 所有 App · 全部桌面")
                    .font(.headline)
                Spacer()
            }
            if entries.isEmpty {
                Text(currentAppOnly ? "当前 App 没有可见窗口，按菜单键查看所有 App"
                                    : "没有可见窗口")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 30)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                                card(entry, isSelected: index == selected).id(index)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                    }
                    .onAppear { proxy.scrollTo(selected, anchor: .center) }
                    .onChange(of: selected) { _, value in
                        withAnimation(Motion.select) {
                            proxy.scrollTo(value, anchor: .center)
                        }
                    }
                    // 两侧渐隐：截断的卡片以淡出收边，暗示可继续滚动
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 64)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 64)
                        }
                    )
                }
            }
        }
        .padding(Spacing.sheetPadding)
        .frame(maxWidth: 1000)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private func card(_ entry: WindowSwitcher.PickerEntry, isSelected: Bool) -> some View {
        VStack(spacing: 8) {
            appIcon(entry.bundleID)
                .frame(width: 60, height: 60)
            Text(entry.window.title.isEmpty ? entry.appName : entry.window.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 156)
            Text(entry.appName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 1 : 0.55),
                    in: RoundedRectangle(cornerRadius: Radius.hud))
        .overlay(RoundedRectangle(cornerRadius: Radius.hud)
            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
        .shadow(color: isSelected ? Color.accentColor.opacity(0.5) : .clear, radius: 6)
        .scaleEffect(isSelected ? 1.06 : 1)
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

/// 系统功能菜单：3 列网格，方向键选择、OK 执行；危险项标红且 OK 按住填充确认。
private struct SystemMenuView: View {
    let selected: Int
    var confirming = false

    var body: some View {
        VStack(spacing: 12) {
            // 操作提示只保留屏底 HintBar 一份（权威），头部不再重复
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3")
                Text("系统功能").font(.headline)
                Spacer()
            }
            let normal = SystemMenuCatalog.items.enumerated().filter { !$0.element.dangerous }
            let dangerous = SystemMenuCatalog.items.enumerated().filter { $0.element.dangerous }
            let columns = Array(repeating: GridItem(.fixed(188), spacing: 12),
                                count: SystemMenuCatalog.columns)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(normal, id: \.offset) { index, item in
                    tile(item, index: index)
                }
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 12) {
                ForEach(dangerous, id: \.offset) { index, item in
                    tile(item, index: index)
                }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    @ViewBuilder
    private func tile(_ item: SystemMenuItem, index: Int) -> some View {
        let isSelected = index == selected
        VStack(spacing: 6) {
            Image(systemName: item.symbol).font(.system(size: 28))
            Text(item.title).font(.callout)
            if item.dangerous {
                Text("按住 OK 确认").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(item.dangerous ? Color.red : Color.primary)
        .frame(width: 180, height: 96)
        .background(Color(nsColor: .controlBackgroundColor)
            .opacity(isSelected ? 1 : 0.55),
            in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(isSelected ? (item.dangerous ? Color.red : Color.accentColor) : .clear, lineWidth: 2.5))
        .overlay(alignment: .topTrailing) {
            if isSelected, confirming {
                ConfirmRingView(duration: SystemMenuCatalog.confirmHoldSeconds)
                    .padding(5)
            }
        }
        .shadow(color: isSelected ? (item.dangerous ? Color.red : Color.accentColor).opacity(0.4) : .clear,
                radius: 6)
        .scaleEffect(isSelected ? 1.06 : 1)
    }
}

/// hold-to-confirm 填充环：出现后在 duration 内线性填满（执行时机由 OverlayCenter 计时器掌握）。
private struct ConfirmRingView: View {
    let duration: TimeInterval
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.red.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 24, height: 24)
        .onAppear { withAnimation(.linear(duration: duration)) { progress = 1 } }
    }
}

/// App 轮盘（停留式）：图标沿圆环排布，中心显示选中 App 名与操作提示。
struct AppWheelView: View {
    struct Entry {
        let name: String
        let bundleID: String?
    }
    let apps: [Entry]
    let selected: Int

    private let radius: CGFloat = 140

    var body: some View {
        VStack(spacing: 10) {
            if apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "circle.dashed").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("暂无最近使用的 App").font(.callout)
                    Text("切换过几个 App 后再试；3 秒后自动关闭").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 30)
            } else {
                ZStack {
                    // 圆环底
                    Circle()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: radius * 2, height: radius * 2)
                    // 中心：选中 App 名 + 取消待定态（Steam radial 规范：中心=取消区）
                    VStack(spacing: 3) {
                        Text(apps.indices.contains(selected) ? apps[selected].name : "")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: radius * 1.3)
                        Text(selected == 0 ? "当前前台" : "最近使用")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle.fill")
                            Text("返回取消")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    }
                    // 图标沿圆环（从正上方起顺时针均布）
                    ForEach(Array(apps.enumerated()), id: \.offset) { index, entry in
                        let angle = Double(index) / Double(apps.count) * 2 * .pi - .pi / 2
                        icon(entry, isSelected: index == selected)
                            .offset(x: radius * CGFloat(cos(angle)),
                                    y: radius * CGFloat(sin(angle)))
                    }
                }
                .frame(width: radius * 2 + 104, height: radius * 2 + 104)
            }
            Text("3 秒无操作自动关闭")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(Spacing.sheetPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    @ViewBuilder
    private func icon(_ entry: Entry, isSelected: Bool) -> some View {
        VStack(spacing: 4) {
            Group {
                if let bundleID = entry.bundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: isSelected ? 78 : 58, height: isSelected ? 78 : 58)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor))
                .padding(-7)
                .shadow(color: isSelected ? Color.accentColor.opacity(0.5) : .clear, radius: 6))
            .overlay(Circle()
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                .padding(-7))
        }
        .animation(Motion.select, value: isSelected)
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
                    .font(.callout.weight(.semibold))
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.0)
                        .font(.caption2.weight(.bold))
                        .frame(width: 38, height: 18)
                        .background(Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: Radius.small))
                    Text(row.1).font(.caption).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.hud))
        .overlay(RoundedRectangle(cornerRadius: Radius.hud)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
