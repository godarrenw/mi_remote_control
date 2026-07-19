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
            .sink { [weak self] _ in self?.refresh() }
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
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        guard let button = statusItem?.button else { return }
        let (symbol, tint, desc) = iconState()
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        img?.isTemplate = tint == nil
        button.image = img
        button.contentTintColor = tint
        // 层激活时叠加数字角标（用 title 简做）
        button.title = model.activeLayer != 0 ? " \(model.activeLayer)" : ""
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

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 状态行（不可点）
        let statusText: String
        if model.connected {
            var parts = ["\(model.deviceName ?? "MI RC 2 Pro") · 已连接"]
            if let pct = model.batteryPercent { parts.append("电量 \(pct)%") }
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

    /// 模式态（层/鼠标/语音）常驻显示；菜单栏图标开着时只在图标关闭后兜底。
    private func refresh() {
        var texts: [String] = []
        if model.activeLayer != 0 { texts.append(modeDisplayName(model.activeLayer)) }
        if model.mouseModeActive { texts.append("🖱 鼠标模式") }
        if model.voiceActive { texts.append("🎙 录音中") }
        // 图标可见时，仅语音/鼠标等瞬时强提示也不重复弹（图标已表达）——只在图标关闭时兜底
        let shouldShow = !texts.isEmpty && !model.showStatusItem
        if shouldShow {
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
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}
