import SwiftUI
import CoreBluetooth

// MARK: - 逐项检测行组件（首启向导 + 升级重授权复用）

@MainActor
struct PermissionCheckRow: View {
    var icon: String
    var title: String
    var explain: String
    var state: EnvCheckState
    var waitingForRestart = false
    var actionTitle: String = "去授权"
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(explain).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .denied:
                Label(waitingForRestart ? "等待重启" : "未授权",
                      systemImage: waitingForRestart ? "arrow.clockwise.circle.fill" : "circle.fill")
                    .font(.caption).foregroundStyle(waitingForRestart ? .orange : .red)
                if let action {
                    Button(actionTitle) { action() }
                        .controlSize(.small)
                }
            case .unknown:
                Label("检测中…", systemImage: "circle.dotted")
                    .font(.caption).foregroundStyle(.secondary)
                if let action {
                    Button(actionTitle) { action() }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 首启三步向导（权限 → BlackHole → 配对）

@MainActor
struct OnboardingWizard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var ax: EnvCheckState = .unknown
    @State private var im: EnvCheckState = .unknown
    @State private var bt: EnvCheckState = .unknown
    /// 必须强持有到 CoreBluetooth 回调返回；瞬时创建后立即释放会让首次授权弹窗不可靠。
    @State private var bluetoothPermissionManager: CBCentralManager?
    @State private var blackhole: EnvCheckState = .unknown
    @State private var remote: EnvCheckState = .unknown
    @State private var pollTimer: Timer?
    @State private var scanTooLong = false
    @State private var axRequestOpened = false
    @State private var imRequestOpened = false
    // 配对步示意图脉动（高亮 主页+返回 两键）
    @State private var pulseTimer: Timer?
    @State private var pairingPulse = true
    // BlackHole 安装后重启音频服务
    @State private var coreAudioBusy = false
    @State private var coreAudioMsg: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                // 步骤指示器
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 20 : 8, height: 8)
                        if i < 2 { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 32, height: 1) }
                    }
                }
                .animation(Motion.focus, value: step)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("稍后设置；下次启动仍会显示向导")
            }
            .padding(.top, 4)

            Group {
                switch step {
                case 0: permissionStep
                case 1: blackHoleStep
                default: pairingStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                if step > 0 { Button("上一步") { step -= 1 } }
                Button("退出 App") {
                    terminateApp(relaunch: false)
                }
                Spacer()
                if step == 0 {
                    if ax != .granted || im != .granted || axRequestOpened || imRequestOpened {
                        Button("退出并重新打开") {
                            terminateApp(relaunch: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("macOS 需要重启 App 才会把新权限应用到输入通道")
                    }
                    Button("下一步") { step = 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(!(ax == .granted && im == .granted && bt == .granted))
                        .help(ax == .granted && im == .granted && bt == .granted ? "" : "授权全部完成后继续")
                } else if step == 1 {
                    Button(blackhole == .granted ? "下一步" : "跳过") { step = 2 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(remote == .granted ? "完成" : "稍后配对，直接完成") {
                        model.hasCompletedOnboarding = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 460, height: 470)
        .onAppear { startPolling() }
        .onDisappear {
            pollTimer?.invalidate(); pollTimer = nil
            pulseTimer?.invalidate(); pulseTimer = nil
        }
    }

    // 第 1 步 · 权限
    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第 1 步 · 授权").font(.title3.bold())
            Text("MiRemote 需要三项系统权限才能接管遥控器按键。输入监控和辅助功能授权后，请点“退出并重新打开”。")
                .font(.caption).foregroundStyle(.secondary)
            PermissionCheckRow(icon: "antenna.radiowaves.left.and.right", title: "蓝牙",
                               explain: "连接遥控器、接收语音音频",
                               state: bt,
                               actionTitle: bt == .denied ? "去系统设置" : "去授权") {
                requestBluetoothPermission()
            }
            PermissionCheckRow(icon: "keyboard", title: "输入监控",
                               explain: "读取遥控器按键事件",
                               state: im,
                               waitingForRestart: imRequestOpened && im != .granted) {
                imRequestOpened = true
                _ = EnvironmentCheck.requestInputMonitoring()
                if let url = EnvironmentCheck.inputMonitoring().guideURL { NSWorkspace.shared.open(url) }
            }
            PermissionCheckRow(icon: "accessibility", title: "辅助功能",
                               explain: "把按键翻译成快捷键/系统动作",
                               state: ax,
                               waitingForRestart: axRequestOpened && ax != .granted) {
                axRequestOpened = true
                _ = EnvironmentCheck.requestAccessibility()
                if let url = EnvironmentCheck.accessibility().guideURL { NSWorkspace.shared.open(url) }
            }
            Text("提示：正式签名版正常更新会保留授权；测试版或签名身份变化时可能需要重新授权。")
                .font(.footnote).foregroundStyle(.tertiary)
        }
    }

    // 第 2 步 · BlackHole
    private var blackHoleStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第 2 步 · BlackHole 虚拟声卡").font(.title3.bold())
            Text("语音输入（遥控器麦克风模式）需要它把音频接进豆包输入法。不用语音可跳过。")
                .font(.caption).foregroundStyle(.secondary)
            PermissionCheckRow(icon: "waveform", title: "BlackHole 2ch",
                               explain: "/Library/Audio/Plug-Ins/HAL/",
                               state: blackhole,
                               actionTitle: "下载安装包") {
                if let url = EnvironmentCheck.blackHole().guideURL { NSWorkspace.shared.open(url) }
            }
            if blackhole != .granted {
                Text("① 点「下载安装包」到官方页面下载 .pkg 并双击安装（安装要输开机密码——用于注册虚拟声卡，安全）。\n② 装好后系统有时不会立刻识别，点下面的按钮重启音频服务（声音会中断约 1 秒，属正常）。\n③ 检测到驱动后本行自动亮绿灯并进入下一步。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        restartCoreAudio()
                    } label: {
                        if coreAudioBusy {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("重启音频服务中…") }
                        } else {
                            Text("我已安装，重启音频服务")
                        }
                    }
                    .disabled(coreAudioBusy)
                    if let coreAudioMsg {
                        Text(coreAudioMsg).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("重启音频服务会弹管理员密码框（执行 killall coreaudiod，让系统重新加载声卡驱动）。")
                    .font(.footnote).foregroundStyle(.tertiary)
            } else {
                Label("已安装，可继续下一步", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    /// 「我已安装，重启音频服务」：osascript 管理员执行 killall coreaudiod。
    private func restartCoreAudio() {
        coreAudioBusy = true
        coreAudioMsg = nil
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e",
                "do shell script \"killall coreaudiod\" with administrator privileges with prompt \"MiRemote 需要重启音频服务以加载 BlackHole 驱动\""]
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch { ok = false }
            DispatchQueue.main.async {
                coreAudioBusy = false
                coreAudioMsg = ok ? "已重启，正在重新检测…" : "未完成（可能取消了密码框），可重试"
            }
        }
    }

    // 第 3 步 · 配对
    private var pairingStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第 3 步 · 配对遥控器").font(.title3.bold())
            if remote == .granted {
                Label("遥控器已连接", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                Text("完成后试试按遥控器上任意一个键——映射页的示意图会实时亮起。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.voiceMode == .remoteMic {
                    Text("使用遥控器麦克风模式前，记得在豆包输入法设置里把麦克风选为 BlackHole 2ch。")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    // 可视化：示意图上高亮 主页+返回 两键并脉动（N-05/N-06 配对无图）
                    RemoteDiagram(selected: .constant(.ok),
                                  flashing: nil,
                                  connected: false,
                                  emphasized: pairingPulse ? [.home, .back] : [],
                                  interactive: false)
                        .frame(width: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("同时长按左侧高亮的两个键——「主页 ⌂」和「返回 ←」——约 3 秒")
                            .font(.callout)
                        Text("指示灯在遥控器顶部电源键旁：快速闪烁 = 进入配对模式；不闪说明没按够 3 秒或电量不足。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("① 长按进入配对 → ② 点下方按钮到系统蓝牙里点「连接」→ ③ 回到这里，连上会自动打勾。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("打开蓝牙设置") {
                            if let url = EnvironmentCheck.remoteConnected().guideURL { NSWorkspace.shared.open(url) }
                        }
                        .controlSize(.small)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在等待遥控器出现…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if scanTooLong {
                    DisclosureGroup("没反应？") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("· 检查遥控器电量（换电池试试）")
                            Text("· 靠近 Mac 半米内重试")
                            Text("· 遥控器可能已连着电视/盒子——先在那边断开")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func startPolling() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            Task { @MainActor in pairingPulse.toggle() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { scanTooLong = true }
    }

    private func refresh() {
        ax = EnvironmentCheck.accessibility().state
        im = EnvironmentCheck.inputMonitoring().state
        bt = CBCentralManager.authorization == .allowedAlways ? .granted
            : (CBCentralManager.authorization == .notDetermined ? .unknown : .denied)
        blackhole = EnvironmentCheck.blackHole().state
        remote = EnvironmentCheck.remoteConnected().state
        // 自动推进：当前步就绪 → 0.6s 后进下一步
        if step == 0, ax == .granted, im == .granted, bt == .granted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if step == 0 { step = 1 }
            }
        } else if step == 1, blackhole == .granted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if step == 1 { step = 2 }
            }
        }
    }

    /// 首次请求由一个被 View 强持有的 central 触发；明确拒绝后 macOS 不会再次弹框，
    /// 此时直接带用户去「隐私与安全性 → 蓝牙」重新开启。
    private func requestBluetoothPermission() {
        switch CBCentralManager.authorization {
        case .notDetermined:
            if bluetoothPermissionManager == nil {
                bluetoothPermissionManager = CBCentralManager(delegate: nil, queue: .main)
            }
        case .denied, .restricted:
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                NSWorkspace.shared.open(url)
            }
        case .allowedAlways:
            refresh()
        @unknown default:
            refresh()
        }
    }

    /// 首启 sheet 期间普通 terminate 会被退出确认/模态层拦住，因此这里先同步清理
    /// BLE、音频与 hidutil，再直接结束进程。重启用独立 helper 延迟拉起同一 app。
    private func terminateApp(relaunch: Bool) {
        relaunch ? AppLifecycle.quitAndRelaunch(model) : AppLifecycle.quit(model)
    }
}

// MARK: - 升级失权检测（ux-flows 旅程 7：无公证分发升级后 cdhash 变化 → TCC 失权）

/// 用 UserDefaults 记住上次运行时两项核心权限的授权状态；本次启动发现
/// 「上次有、这次没」即判定为升级失权，自动弹精简重授权 sheet。
enum PermissionMemory {
    /// 上次记录为已授权、但当前已失效的权限名列表（空 = 无失权）。
    static func lostPermissions() -> [String] {
        let d = UserDefaults.standard
        var lost: [String] = []
        if d.bool(forKey: Prefs.lastAxGranted),
           EnvironmentCheck.accessibility().state != .granted { lost.append("辅助功能") }
        if d.bool(forKey: Prefs.lastImGranted),
           EnvironmentCheck.inputMonitoring().state != .granted { lost.append("输入监控") }
        return lost
    }

    /// 把当前授权状态写入快照（授权只增不减地记录：拿到过就记 true，
    /// 直到重授 sheet 完成才刷新，避免失权后快照被覆盖导致下次不再提醒）。
    static func snapshot() {
        let d = UserDefaults.standard
        if EnvironmentCheck.accessibility().state == .granted { d.set(true, forKey: Prefs.lastAxGranted) }
        if EnvironmentCheck.inputMonitoring().state == .granted { d.set(true, forKey: Prefs.lastImGranted) }
    }
}

/// 精简重授权 sheet（复用向导第 1 步的 PermissionCheckRow）。
@MainActor
struct ReauthSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var ax: EnvCheckState = .unknown
    @State private var im: EnvCheckState = .unknown
    @State private var pollTimer: Timer?

    private var allGranted: Bool { ax == .granted && im == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检测到你更新了版本，需要重新授权一次").font(.title3.bold())
            Text("这是 macOS 的安全机制：测试版每次更新都要重新点一下授权，30 秒搞定。你的所有按键设置都还在（配置文件不受升级影响）。")
                .font(.caption).foregroundStyle(.secondary)

            PermissionCheckRow(icon: "keyboard", title: "输入监控",
                               explain: "读取遥控器按键事件",
                               state: im) {
                _ = EnvironmentCheck.requestInputMonitoring()
                if let url = EnvironmentCheck.inputMonitoring().guideURL { NSWorkspace.shared.open(url) }
            }
            PermissionCheckRow(icon: "accessibility", title: "辅助功能",
                               explain: "把按键翻译成快捷键/系统动作",
                               state: ax) {
                _ = EnvironmentCheck.requestAccessibility()
                if let url = EnvironmentCheck.accessibility().guideURL { NSWorkspace.shared.open(url) }
            }

            Spacer(minLength: 0)
            HStack {
                Button("稍后再说") { dismiss() }
                Spacer()
                if allGranted {
                    Button("重启 App 生效") {
                        PermissionMemory.snapshot()
                        AppLifecycle.quitAndRelaunch(model)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("授权后此处自动亮绿灯").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 430, height: 260)
        .onAppear {
            refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
    }

    private func refresh() {
        ax = EnvironmentCheck.accessibility().state
        im = EnvironmentCheck.inputMonitoring().state
    }
}
