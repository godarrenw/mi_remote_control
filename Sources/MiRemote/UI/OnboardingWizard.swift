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
                        .buttonStyle(.borderedProminent)
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
    @State private var blackhole: EnvCheckState = .unknown
    @State private var remote: EnvCheckState = .unknown
    @State private var pollTimer: Timer?
    @State private var scanTooLong = false
    @State private var axRequestOpened = false
    @State private var imRequestOpened = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                // 步骤指示器
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        if i < 2 { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 32, height: 1) }
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
                    if axRequestOpened || imRequestOpened {
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
                        .buttonStyle(blackhole == .granted ? .borderedProminent : .borderedProminent)
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
        .frame(width: 460, height: 420)
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
    }

    // 第 1 步 · 权限
    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第 1 步 · 授权").font(.title3.bold())
            Text("MiRemote 需要三项系统权限才能接管遥控器按键。输入监控和辅助功能授权后，请点“退出并重新打开”。")
                .font(.caption).foregroundStyle(.secondary)
            PermissionCheckRow(icon: "antenna.radiowaves.left.and.right", title: "蓝牙",
                               explain: "连接遥控器、接收语音音频",
                               state: bt) {
                // 触发系统蓝牙授权（创建 central 即弹框）；已授权则无感
                _ = CBCentralManager()
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
                .font(.system(size: 10)).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
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
                               actionTitle: "打开下载页") {
                if let url = EnvironmentCheck.blackHole().guideURL { NSWorkspace.shared.open(url) }
            }
            if blackhole != .granted {
                Text("下载安装包并安装（需要输入开机密码，用于注册虚拟声卡）。安装后声音会中断约 1 秒，属正常。装好后本页自动打勾。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("已安装，可继续下一步", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
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
                HStack(spacing: 12) {
                    Image(systemName: "av.remote")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("长按遥控器「主页键 + 返回键」约 3 秒，直到指示灯闪烁")
                            .font(.callout)
                        Button("打开蓝牙设置") {
                            if let url = EnvironmentCheck.remoteConnected().guideURL { NSWorkspace.shared.open(url) }
                        }
                        .controlSize(.small)
                    }
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在等待遥控器出现…").font(.caption).foregroundStyle(.secondary)
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

    /// 首启 sheet 期间普通 terminate 会被退出确认/模态层拦住，因此这里先同步清理
    /// BLE、音频与 hidutil，再直接结束进程。重启用独立 helper 延迟拉起同一 app。
    private func terminateApp(relaunch: Bool) {
        model.services?.stop()
        if relaunch, Bundle.main.bundleURL.pathExtension == "app" {
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "miremote-relaunch",
                                Bundle.main.bundleURL.path]
            do {
                try helper.run()
            } catch {
                log("自动重开失败，请手动重新打开 App：\(error.localizedDescription)")
            }
        }
        exit(EXIT_SUCCESS)
    }
}
