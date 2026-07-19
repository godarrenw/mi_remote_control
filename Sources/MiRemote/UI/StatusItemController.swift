import AppKit
import SwiftUI
import Combine

// MARK: - 菜单栏图标（菜单栏优先形态的主入口）
//
// 左键点击 = SwiftUI 状态面板（NSPopover）；右键 / Option+左键 = 传统 NSMenu 兜底。
// 图标为模板图（单色随系统着色），6 态用着色/透明度/角标短名表达而不换整图；
// autosaveName 固定以保留排序；“显示菜单栏图标”偏好是可见性权威数据源。
// 用户 Cmd+拖走可在当前会话隐藏，但下次启动（或开关重开）会按偏好恢复，
// 避免旧 autosave 的 false 让图标永久消失。

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    var onOpenWindow: (() -> Void)?
    var onQuit: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        // 任一状态变化 → 重绘图标与菜单
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange 在属性真正写入前发送；延后一拍才能读到新电量/连接状态。
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
    }

    /// 图标当前是否可见（用户可能 Cmd+拖走；autosave 持久，供通用页开关状态同步/恢复）。
    var itemVisible: Bool {
        get { statusItem?.isVisible ?? false }
        set { statusItem?.isVisible = newValue }
    }

    private func refresh() {
        if !model.showStatusItem {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            return
        }
        if statusItem == nil {
            // variableLength：层激活时图标旁要放语义短名
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "com.miremote.statusitem"
            item.behavior = .removalAllowed
            // 设置 autosaveName 后系统会读取历史 isVisible；显式覆盖为偏好值。
            item.isVisible = true
            if let button = item.button {
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            statusItem = item
        }
        guard let button = statusItem?.button else { return }
        let (tint, dimmed, desc) = iconState()
        // 模板底图恒为遥控器轮廓，状态用着色/透明度表达（失联=降透明度）
        var img = NSImage(systemSymbolName: "av.remote", accessibilityDescription: desc)
        if dimmed, let base = img {
            let faded = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
                return true
            }
            faded.isTemplate = true
            img = faded
        } else {
            img?.isTemplate = tint == nil
        }
        button.image = img
        button.contentTintColor = tint
        // 层激活时叠加语义短名（P3：显示名字而非数字）；精简模式仅图标
        button.title = (!model.statusItemCompact && model.activeLayer != 0)
            ? " \(layerShortText(model.activeLayer))" : ""
        button.toolTip = tooltipText()
        button.imagePosition = .imageLeading
    }

    /// 6 态：故障红 > 语音 > 鼠标 > 层 > 未连接（降透明度）> 空闲
    private func iconState() -> (tint: NSColor?, dimmed: Bool, desc: String) {
        if model.degraded { return (.systemRed, false, "故障") }
        if model.voiceActive { return (.controlAccentColor, false, "语音中") }
        if model.mouseModeActive { return (.systemGreen, false, "鼠标模式") }
        if model.activeLayer != 0 { return (.controlAccentColor, false, modeDisplayName(model.activeLayer)) }
        if !model.connected { return (nil, true, "未连接") }
        return (nil, false, "已连接")
    }

    /// tooltip 与浮动角标同步的完整语义描述（P3/P9）。
    private func tooltipText() -> String {
        var parts: [String] = ["MiRemote"]
        if model.degraded { parts.append("故障：按键通道异常，打开体检修复") }
        if model.voiceActive { parts.append("录音中") }
        if model.mouseModeActive { parts.append("鼠标模式") }
        if model.activeLayer != 0 {
            parts.append(layerBadgeText(model.activeLayer, frontAppName: model.frontAppNameForBadge))
        }
        if parts.count == 1 { parts.append(model.connected ? "已连接 · 空闲" : "遥控器未连接") }
        return parts.joined(separator: " · ")
    }

    // MARK: 点击路由：左键=状态面板，右键/Option=传统菜单兜底

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.option) == true
        if isRight {
            showFallbackMenu()
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        // 外观跟随 App（NSApp.appearance 覆盖优先）：popover 从状态栏窗口继承的外观
        // 不一定等于 App 外观，显式下发到 popover 与内容视图两层，浅色下必须是浅色面板。
        let appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        p.appearance = appearance
        let hosting = NSHostingController(
            rootView: StatusPanelView(
                onOpenWindow: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.onOpenWindow?()
                },
                onHealthCheck: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.onOpenWindow?()
                    NotificationCenter.default.post(name: .miremoteShowHealthCheck, object: nil)
                },
                onQuit: { [weak self] in self?.onQuit?() })
                .environmentObject(model))
        hosting.view.appearance = appearance
        p.contentViewController = hosting
        popover = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.popover = nil }
    }

    /// 传统 NSMenu 兜底（statusItem.menu 常态必须为 nil，否则会吞掉左键面板）。
    private func showFallbackMenu() {
        guard let item = statusItem else { return }
        item.menu = buildMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开设置窗口", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let health = NSMenuItem(title: "一键体检与修复…", action: #selector(showHealth), keyEquivalent: "")
        health.target = self
        menu.addItem(health)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MiRemote", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openWindow() { onOpenWindow?() }
    @objc private func quit() { onQuit?() }
    @objc private func showHealth() {
        onOpenWindow?()
        NotificationCenter.default.post(name: .miremoteShowHealthCheck, object: nil)
    }
}

// MARK: - 菜单栏状态面板（SwiftUI，NSPopover 内容）

struct StatusPanelView: View {
    @EnvironmentObject var model: AppModel
    var onOpenWindow: () -> Void
    var onHealthCheck: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.intra) {
            statusCard
            Divider()
            Toggle(isOn: Binding(
                get: { model.remoteSuspended },
                set: { model.setRemoteSuspended($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("暂停遥控").font(.body)
                    Text("按键与手势暂不生效，真实键盘不受影响")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("语音输入").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.voiceMode) {
                    Text("遥控器麦克风").tag(VoiceMode.remoteMic)
                    Text("Mac 麦克风").tag(VoiceMode.macMic)
                    Text("关闭").tag(VoiceMode.off)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Divider()
            HStack(spacing: Spacing.intra) {
                Button("打开设置", action: onOpenWindow)
                Button("一键体检", action: onHealthCheck)
                Spacer()
                Button(role: .destructive, action: onQuit) {
                    Image(systemName: "power")
                }
                .help("退出 MiRemote（恢复真实键盘）")
            }
            .controlSize(.small)
        }
        .padding(Spacing.rowH)
        .frame(width: 300)
        // 不透明系统底色：外观明确分离浅/深（vibrant 材质会采样身后桌面，浅色下可能显脏）
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.syncRemoteSuspended() }
    }

    // 顶部状态卡：设备名 + 连接/模式行 + 电量环 + 健康点
    private var statusCard: some View {
        HStack(spacing: Spacing.intra) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.badge)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "av.remote")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.deviceName ?? "MI RC 2 Pro").font(.body.weight(.semibold))
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let pct = model.batteryPercent {
                BatteryRingView(percent: pct)
            }
            Circle()
                .fill(model.degraded ? Color.red : (model.connected ? Color.green : Color.secondary.opacity(0.4)))
                .frame(width: 8, height: 8)
                .help(model.degraded ? "按键通道异常" : (model.connected ? "运行正常" : "未连接"))
        }
    }

    private var statusLine: String {
        if !model.connected { return "未连接 · 长按 主页+返回 配对" }
        if model.remoteSuspended { return "已连接 · 已暂停遥控" }
        var parts = ["已连接"]
        if model.activeLayer != 0 {
            parts.append(layerBadgeText(model.activeLayer, frontAppName: model.frontAppNameForBadge))
        } else if model.mouseModeActive {
            parts.append("鼠标模式")
        } else if model.voiceActive {
            parts.append("录音中")
        } else {
            parts.append("空闲")
        }
        return parts.joined(separator: " · ")
    }
}

/// 小电量环：accent 弧线 + 百分比数字，低电量转红。
struct BatteryRingView: View {
    let percent: Int

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, percent))) / 100)
                .stroke(percent <= 15 ? Color.red : Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)")
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
        .frame(width: 28, height: 28)
        .help("电量 \(percent)%")
    }
}

// MARK: - 浮动角标（NSPanel，非侵入，右下角小徽章）

@MainActor
final class FloatingBadgeController {
    private var panel: NSPanel?
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    /// 场景切换闪现（gamepad-ux C2：前台 App 变化致 per-app 覆盖生效时提示「XX 布局」）
    private var flashUntil: Date?
    private var lastProfileBundle: String?

    init(model: AppModel) {
        self.model = model
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.noteFrontApp(app) }
        }
    }

    /// 前台 App 变化：切进有专用场景的 App 时闪现「<App名> 布局」1.2s（复用本角标，不新造浮窗）。
    private func noteFrontApp(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        let hasOverlay = model.config.profiles[bundleID] != nil
        defer { lastProfileBundle = hasOverlay ? bundleID : nil }
        guard hasOverlay, bundleID != lastProfileBundle else { return }
        flash(text: "\(app.localizedName ?? bundleID) 布局")
    }

    private func flash(text: String, duration: TimeInterval = 1.2) {
        flashUntil = Date().addingTimeInterval(duration)
        show(text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, let until = self.flashUntil, Date() >= until else { return }
            self.flashUntil = nil
            self.refresh()
        }
    }

    /// 模式态（层/鼠标/语音）常驻显示语义名（P3/P9：屏幕角落胶囊是模式可见性的主渠道，
    /// 不再只做菜单栏图标关闭后的兜底——20px 小图标瞟一眼分不清在哪个模式）。
    private func refresh() {
        // 闪现期间不被常规状态刷新覆盖
        if let until = flashUntil, Date() < until { return }
        var texts: [String] = []
        if model.activeLayer != 0 {
            texts.append(layerBadgeText(model.activeLayer, frontAppName: model.frontAppNameForBadge))
        }
        if model.mouseModeActive { texts.append("🖱 鼠标模式") }
        if model.voiceActive { texts.append("🎙 录音中") }
        if !texts.isEmpty {
            show(text: texts.joined(separator: " · "))
        } else {
            hide()
        }
    }

    private func show(text: String) {
        let content = NSHostingView(rootView:
            Text(text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.72)))
        )
        content.frame.size = content.fittingSize

        if panel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true            // 可点穿
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel = p
        }
        guard let panel else { return }
        panel.contentView = content
        let size = content.fittingSize
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.maxX - size.width - 24, y: f.minY + 24,
                                  width: size.width, height: size.height), display: true)
        }
        // 进入模式：淡入（已在前台则只换内容不重播动画）
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fadeInDuration
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        // 退出模式：淡出后收起
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }
}
