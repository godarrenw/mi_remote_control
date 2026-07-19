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
    private var overlayCenter: OverlayCenter?

    init(uiPreview: Bool) {
        self.uiPreview = uiPreview
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        configureMainMenu()

        var opts = AppServices.Options()
        opts.keys = true
        opts.perAppVoiceRouting = true
        let levelSink = LevelMeterSink()
        opts.levelSink = levelSink
        let services = AppServices(options: opts)
        self.services = services

        model = AppModel(services: services)

        // M5 v2 浮层体系：窗口选择器 / 系统功能菜单 / 教程浮层（捕获式）+ 控制模式 HUD。
        let center = OverlayCenter(model: model, services: services)
        overlayCenter = center
        ActionRunner.onOverlay = { name in
            // ActionRunner 已切主线程投递
            MainActor.assumeIsolated { center.open(name) }
        }

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

    /// 纯代码创建 NSApplication 时系统不会自动生成主菜单；显式补齐标准快捷键，
    /// 否则菜单栏里的 App 菜单为空，⌘Q/⌘H/⌘W 都不会生效。
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appRoot = NSMenuItem()
        let appMenu = NSMenu(title: "MiRemote")
        let about = NSMenuItem(title: "关于 MiRemote",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: "隐藏 MiRemote",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(hide)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 MiRemote",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appRoot.submenu = appMenu
        mainMenu.addItem(appRoot)

        let windowRoot = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let close = NSMenuItem(title: "关闭窗口",
                               action: #selector(NSWindow.performClose(_:)),
                               keyEquivalent: "w")
        windowMenu.addItem(close)
        let minimize = NSMenuItem(title: "最小化",
                                  action: #selector(NSWindow.performMiniaturize(_:)),
                                  keyEquivalent: "m")
        windowMenu.addItem(minimize)
        windowRoot.submenu = windowMenu
        mainMenu.addItem(windowRoot)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 首次关窗说明「关窗 ≠ 退出」（N-10/25/27 心智坑）：一次性面板 + 不再提示
        let d = UserDefaults.standard
        if !d.bool(forKey: Prefs.closeNoticeAcknowledged) {
            let alert = NSAlert()
            alert.messageText = "MiRemote 转入后台，继续工作"
            alert.informativeText = """
            关闭窗口不会退出：MiRemote 会留在后台继续控制遥控器，Dock 图标随之隐藏。
            · 想再打开设置：点菜单栏遥控器图标，或从启动台 / Spotlight 打开 MiRemote。
            · 想真正退出：菜单栏图标 →「退出 MiRemote」（退出时自动恢复真实键盘）。
            · 卸载前请务必先退出，否则按键中转可能残留、影响真实键盘。
            """
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "不再提示"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                d.set(true, forKey: Prefs.closeNoticeAcknowledged)
            }
        }
        return true
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
                DispatchQueue.main.async {
                    self?.model.noteLayer(layer)
                    self?.overlayCenter?.noteLayer(layer)   // 层2=App 控制模式 HUD
                }
            }
            // 全局逃生键（长按菜单 1.5s）：引擎已自清层态与捕获态，主线程回调；
            // UI 侧同步收掉全部浮层/HUD（角标随 onLayerChanged 归零自动消失）。
            km.engine.onEscapeHatch = { [weak self] in
                MainActor.assumeIsolated { self?.overlayCenter?.escapeHatch() }
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
