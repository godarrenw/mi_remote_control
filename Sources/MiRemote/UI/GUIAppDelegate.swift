import AppKit
import SwiftUI

/// GUI 模式的应用委托：服务生命周期 + 双形态窗口（DESIGN §6.1）+ 状态反馈三件套。
/// --ui-preview：窗口照常，引擎不启动（开发验证专用）。
@MainActor
final class GUIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let uiPreview: Bool
    private var services: AppServices?
    private var model: AppModel!
    private var window: NSWindow?
    private var statusController: StatusItemController?
    private var badgeController: FloatingBadgeController?

    init(uiPreview: Bool) {
        self.uiPreview = uiPreview
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        var opts = AppServices.Options()
        opts.keys = true
        let levelSink = LevelMeterSink()
        opts.levelSink = levelSink
        let services = AppServices(options: opts)
        self.services = services

        model = AppModel(services: services)

        // 服务事件 → 主线程 → AppModel
        wireCallbacks(services: services, levelSink: levelSink)

        // 状态三件套
        statusController = StatusItemController(model: model)
        statusController?.onOpenWindow = { [weak self] in self?.showWindow() }
        statusController?.onQuit = { NSApp.terminate(nil) }
        badgeController = FloatingBadgeController(model: model)

        if uiPreview {
            log("UI 预览模式：引擎不启动")
        } else {
            model.applyVoiceMode()   // 语音模式偏好落到服务开关
            services.start()
        }

        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前清理：恢复 hidutil 中转、断开语音链路（AppServices.stop 幂等）。
        services?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出确认（可在通用页关闭）：仅在引擎真的在跑时提示。
        guard model.exitConfirm, let services, services.started, !uiPreview else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "退出 MiRemote？"
        alert.informativeText = "退出后遥控器将不再控制这台 Mac，按键中转会恢复，真实键盘不受影响。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: 窗口双形态

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let root = RootView().environmentObject(model!)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "MiRemote 设置"
            w.contentView = NSHostingView(rootView: root)
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗不退出：转后台 accessory，隐藏 Dock 图标；服务照跑。
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: 服务事件接线

    private func wireCallbacks(services: AppServices, levelSink: LevelMeterSink) {
        let healthConnection = services.voiceApp.onConnection
        services.voiceApp.onConnection = { [weak self] ok, name in
            healthConnection?(ok, name)
            DispatchQueue.main.async { self?.model.noteConnection(ok, name: name) }
        }
        services.voiceApp.onVoiceActive = { [weak self] active in
            DispatchQueue.main.async { self?.model.noteVoice(active) }
        }
        services.bridge.onBatteryLevel = { [weak self] pct in
            DispatchQueue.main.async { self?.model.noteBattery(pct) }
        }
        levelSink.onLevel = { [weak self] rms in
            DispatchQueue.main.async { self?.model.noteLevel(rms) }
        }
        services.health.onChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.model.degraded = state != .healthy
            }
        }
        // keys 链路的钩子要等 start() 建好 keyMapper 才能挂——start 是同步的，这里延后一拍挂。
        DispatchQueue.main.async { [weak self] in
            guard let self, let km = services.keyMapper, let filter = services.hidFilter else { return }
            km.onLayerChanged = { [weak self] layer in
                DispatchQueue.main.async { self?.model.noteLayer(layer) }
            }
            let healthSeize = km.onSeizeState
            km.onSeizeState = { [weak self] ok in
                healthSeize?(ok)
                DispatchQueue.main.async { self?.model.noteSeize(ok) }
            }
            km.onButtonEvent = { [weak self] ev in
                DispatchQueue.main.async { self?.model.noteButton(ev) }
            }
            // IOHID 原始通道：全部 13 键的「按下即亮」与识别按键都靠它。
            filter.onRawButton = { [weak self] ev in
                DispatchQueue.main.async { self?.model.noteButton(ev) }
            }
        }
    }
}
