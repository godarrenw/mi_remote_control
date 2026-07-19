import AppKit
import SwiftUI
import Combine

// MARK: - 菜单栏图标（6 态语义，ux-flows §2.2）

@MainActor
final class StatusItemController: NSObject {

    private var statusItem: NSStatusItem?
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
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        guard let button = statusItem?.button else { return }
        let (symbol, tint, desc) = iconState()
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        img?.isTemplate = tint == nil
        button.image = img
        button.contentTintColor = tint
        // 层激活时叠加语义短名（P3：显示名字而非数字）；tooltip 给全名
        button.title = model.activeLayer != 0 ? " \(layerShortText(model.activeLayer))" : ""
        button.toolTip = tooltipText()
        button.imagePosition = .imageLeading
        statusItem?.menu = buildMenu()
    }

    /// 6 态：故障红 > 语音 > 鼠标 > 层 > 未连接 > 空闲
    private func iconState() -> (symbol: String, tint: NSColor?, desc: String) {
        if model.degraded { return ("exclamationmark.triangle.fill", .systemRed, "故障") }
        if model.voiceActive { return ("mic.fill", .controlAccentColor, "语音中") }
        if model.mouseModeActive { return ("cursorarrow", .systemGreen, "鼠标模式") }
        if model.activeLayer != 0 { return ("switch.2", .controlAccentColor, modeDisplayName(model.activeLayer)) }
        if !model.connected { return ("av.remote", nil, "未连接") }
        return ("av.remote.fill", nil, "已连接")
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

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 状态行（不可点）
        let statusText: String
        if model.connected {
            var parts = ["\(model.deviceName ?? "MI RC 2 Pro") · 已连接"]
            if let pct = model.batteryPercent {
                parts.append("电量 \(pct)%")
            } else {
                parts.append("电量读取中")
            }
            if model.activeLayer != 0 { parts.append(modeDisplayName(model.activeLayer)) }
            statusText = parts.joined(separator: " · ")
        } else {
            statusText = "遥控器未连接"
        }
        let statusRow = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)

        let open = NSMenuItem(title: "打开设置窗口", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        // 快捷开关：语音模式
        let voiceMenu = NSMenu()
        for (mode, name) in [(VoiceMode.remoteMic, "遥控器麦克风"), (.macMic, "Mac 内置麦克风"), (.off, "关闭")] {
            let item = NSMenuItem(title: name, action: #selector(switchVoiceMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = model.voiceMode == mode ? .on : .off
            voiceMenu.addItem(item)
        }
        let voiceRoot = NSMenuItem(title: "语音模式", action: nil, keyEquivalent: "")
        menu.addItem(voiceRoot)
        menu.setSubmenu(voiceMenu, for: voiceRoot)

        menu.addItem(.separator())
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
    @objc private func switchVoiceMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = VoiceMode(rawValue: raw) {
            model.voiceMode = mode
        }
    }
}

// MARK: - 浮动角标（NSPanel，非侵入，右下角小徽章）

@MainActor
final class FloatingBadgeController {
    private var panel: NSPanel?
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// 模式态（层/鼠标/语音）常驻显示语义名（P3/P9：屏幕角落胶囊是模式可见性的主渠道，
    /// 不再只做菜单栏图标关闭后的兜底——20px 小图标瞟一眼分不清在哪个模式）。
    private func refresh() {
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
                .font(.system(size: 12, weight: .semibold))
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
                ctx.duration = 0.18
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
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }
}
