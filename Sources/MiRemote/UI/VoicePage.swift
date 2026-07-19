import SwiftUI
import Carbon.HIToolbox

/// 当前键盘输入法的 InputSourceID（如 "com.bytedance.inputmethod.Doubao..."）。
func currentInputSourceID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

@MainActor
struct VoicePage: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedProfile = "global"
    @State private var showAddApp = false
    // 链路自检状态（N-17：跨 3 个 App 的语音链路逐项亮灯）
    @State private var hadAudioFrames = false
    @State private var imeIsDoubao = false
    @State private var remoteSeen = false
    @State private var checkTimer: Timer?

    private let triggerKeys: [(String, String)] = [
        ("right_option", "右 Option ⌥（推荐）"), ("left_option", "左 Option ⌥"),
        ("f13", "F13（Typeless / Superwhisper 常用）"), ("f5", "F5"), ("fn", "Fn"),
        ("right_cmd", "右 Command ⌘"), ("left_cmd", "左 Command ⌘"),
        ("right_ctrl", "右 Control ⌃"), ("left_ctrl", "左 Control ⌃"),
        ("right_shift", "右 Shift ⇧"), ("left_shift", "左 Shift ⇧"),
    ]

    private var selectableProfiles: [String] {
        ["global"] + model.config.profiles.keys.filter { $0 != "global" }.sorted {
            profileDisplayName($0) < profileDisplayName($1)
        }
    }

    private var blackHoleInstalled: Bool {
        EnvironmentCheck.blackHole().state == .granted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                PageHeader(title: "语音",
                           subtitle: "选择音频来源，并为不同 App 自动发送各自的语音输入快捷键。")

                if model.voiceMode == .remoteMic && !blackHoleInstalled {
                    Label("BlackHole 未安装，遥控器麦克风模式不可用", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                SettingsGroup(title: "输入模式") {
                    modeRow(.remoteMic, title: "遥控器麦克风（主打）",
                            subtitle: "按住语音键说话，音频经蓝牙传回并解码为 16kHz PCM")
                    RowDivider()
                    modeRow(.macMic, title: "Mac 内置麦克风",
                            subtitle: "按键仅触发豆包语音输入，用 Mac 麦克风收音")
                    RowDivider()
                    modeRow(.off, title: "关闭",
                            subtitle: "语音键可另行映射为普通按键")
                }

                SettingsGroup(title: "按 App 的语音快捷键") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("适用 App").font(.body)
                            Spacer()
                            Picker("", selection: $selectedProfile) {
                                ForEach(selectableProfiles, id: \.self) { profile in
                                    Text(profileDisplayName(profile)).tag(profile)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                            Button { showAddApp = true } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .help("从运行中的 App 添加")
                        }
                        RowDivider()
                        HStack {
                            Text("触发按键").font(.body)
                            Spacer()
                            Picker("", selection: triggerKeyBinding) {
                                ForEach(triggerKeys, id: \.0) { item in Text(item.1).tag(item.0) }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        HStack {
                            Text("触发方式").font(.body)
                            Spacer()
                            Picker("", selection: triggerModeBinding) {
                                Text("按住说话").tag("hold")
                                Text("单击开始 / 再击结束").tag("tap")
                                Text("双击开始 / 单击结束").tag("double")
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        HStack {
                            Text("语音工具").font(.body)
                            Spacer()
                            Picker("", selection: imeModeBinding) {
                                Text("豆包输入法（自动切换）").tag("doubao")
                                Text("独立语音 App（不切输入法）").tag("standalone")
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        if selectedProfile != "global" {
                            HStack {
                                Text(model.hasCustomVoiceRule(for: selectedProfile)
                                     ? "此 App 使用独立设置" : "此 App 正在继承全局设置")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if model.hasCustomVoiceRule(for: selectedProfile) {
                                    Button("恢复继承全局") {
                                        model.resetVoiceRuleToGlobal(for: selectedProfile)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                        Text("这里设置的是遥控器开始传音时，MiRemote 向当前 App 发送的快捷键。请先在对应语音工具里设成同一个键。")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(Spacing.cardPadding)
                }

                linkSelfCheckGroup

                doubaoGuideGroup

                SettingsGroup(title: "BlackHole 虚拟声卡") {
                    SettingsRow(icon: blackHoleInstalled ? "checkmark.circle.fill" : "xmark.circle.fill",
                                iconColor: blackHoleInstalled ? .green : .red,
                                title: blackHoleInstalled ? "已安装 · 运行正常" : "未安装",
                                subtitle: "BlackHole 2ch · /Library/Audio/Plug-Ins/HAL/") {
                        Button(blackHoleInstalled ? "重新安装" : "去下载") {
                            if let url = EnvironmentCheck.blackHole().guideURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                SettingsGroup(title: "实时电平表") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("按住语音键说话，可实时看到波形跳动")
                            .font(.caption).foregroundStyle(.secondary)
                        LevelMeterView(bars: model.levelBars, active: model.voiceActive)
                        RowDivider().padding(.leading, -44)
                        HStack {
                            Text("输入增益").font(.body)
                            Slider(value: $model.voiceGainDb, in: -12...12, step: 1)
                            Text(String(format: "%+.0f dB", model.voiceGainDb))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                        Text("增益改动在下次语音会话生效")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(Spacing.cardPadding)
                }
            }
            .padding(Spacing.page)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showAddApp) { AddRunningAppSheet() }
        .onAppear {
            refreshLinkCheck()
            checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in refreshLinkCheck() }
            }
        }
        .onDisappear { checkTimer?.invalidate(); checkTimer = nil }
        .onChange(of: model.levelBars) { _, bars in
            // 语音会话期间收到非零电平 = 音频帧真的到了
            if model.voiceActive, (bars.last ?? 0) > 0.02 { hadAudioFrames = true }
        }
    }

    private func refreshLinkCheck() {
        imeIsDoubao = currentInputSourceID()?.hasPrefix("com.bytedance.inputmethod") == true
        remoteSeen = model.connected || EnvironmentCheck.remoteConnected().state == .granted
    }

    // MARK: 链路自检（逐项亮灯，每项失败给一句修法）

    private enum CheckLight { case ok, bad, pending }

    private var linkSelfCheckGroup: some View {
        SettingsGroup(title: "链路自检") {
            checkRow(light: blackHoleInstalled ? .ok : .bad,
                     title: "BlackHole 已安装",
                     fix: "没装：在下方「BlackHole 虚拟声卡」点“去下载”，装完回到首启向导第 2 步重启音频服务。")
            RowDivider()
            checkRow(light: remoteSeen ? .ok : .bad,
                     title: "遥控器已连接",
                     fix: "没连上：检查电量并靠近 Mac；仍不行就长按 主页+返回 3 秒重新配对。")
            RowDivider()
            checkRow(light: hadAudioFrames ? .ok : (model.voiceActive ? .bad : .pending),
                     title: "按语音键有音频帧",
                     fix: "现在按住遥控器语音键说一句话——下方电平表跳动即通过；不跳请确认输入模式选了「遥控器麦克风」。",
                     pendingText: "待检测（按住语音键说话）")
            RowDivider()
            checkRow(light: imeIsDoubao ? .ok : .bad,
                     title: "当前输入法是豆包",
                     fix: "点菜单栏输入法图标切到豆包输入法；没装豆包则先安装并在系统设置里启用它。")
        }
    }

    @ViewBuilder
    private func checkRow(light: CheckLight, title: String, fix: String, pendingText: String = "未通过") -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: light == .ok ? "checkmark.circle.fill"
                  : (light == .pending ? "circle.dotted" : "xmark.circle.fill"))
                .foregroundStyle(light == .ok ? Color.green : (light == .pending ? Color.secondary : Color.red))
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if light != .ok {
                    Text(fix).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if light != .ok {
                Text(light == .pending ? pendingText : "未通过")
                    .font(.caption)
                    .foregroundStyle(light == .pending ? Color.secondary : Color.orange)
            }
        }
        .padding(.horizontal, Spacing.rowH)
        .padding(.vertical, Spacing.rowV)
    }

    // MARK: 豆包麦克风设置图文（N-16；文字版分步，图占位）

    private var doubaoGuideGroup: some View {
        SettingsGroup(title: "豆包麦克风设置（遥控器麦克风模式必做一次）") {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 打开「豆包」App → 点右下角头像进入设置。")
                Text("2. 找到「语音 / 麦克风」设置项。")
                Text("3. 把麦克风（音频输入设备）从默认改为 **BlackHole 2ch**。")
                Text("4. 回到这里按住遥控器语音键说话——上方自检第 3 项变绿即成功。")
                doubaoMicIllustration
                Text("只需要设置一次；说话时 MiRemote 会临时把系统输入切到 BlackHole，松开语音键约 1 秒后自动还原。")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(Spacing.cardPadding)
        }
    }

    /// 豆包麦克风设置示意（矢量绘制的迷你设置行，代替裸占位矩形）。
    private var doubaoMicIllustration: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
                Text("豆包 · 设置").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(Color.accentColor)
                Text("麦克风").font(.caption)
                Spacer()
                HStack(spacing: 4) {
                    Text("BlackHole 2ch").font(.caption.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.small))
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tertiary)
                Text("扬声器").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("系统默认").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.badge))
        .overlay(RoundedRectangle(cornerRadius: Radius.badge)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private var triggerKeyBinding: Binding<String> {
        Binding(get: { model.voiceRule(for: selectedProfile).keyName }, set: { value in
            model.updateVoiceRule(for: selectedProfile) { $0.keyName = value }
        })
    }

    private var triggerModeBinding: Binding<String> {
        Binding(get: { model.voiceRule(for: selectedProfile).mode }, set: { value in
            model.updateVoiceRule(for: selectedProfile) { $0.mode = value }
        })
    }

    private var imeModeBinding: Binding<String> {
        Binding(get: {
            model.voiceRule(for: selectedProfile).imeBundlePrefix == nil ? "standalone" : "doubao"
        }, set: { value in
            model.updateVoiceRule(for: selectedProfile) {
                $0.imeBundlePrefix = value == "standalone" ? nil : "com.bytedance.inputmethod"
            }
        })
    }

    @ViewBuilder
    private func modeRow(_ mode: VoiceMode, title: String, subtitle: String) -> some View {
        Button {
            model.voiceMode = mode
        } label: {
            SettingsRow(icon: model.voiceMode == mode ? "largecircle.fill.circle" : "circle",
                        iconColor: model.voiceMode == mode ? .accentColor : .secondary,
                        title: title, subtitle: subtitle) {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct LevelMeterView: View {
    var bars: [Float]
    var active: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                let h = max(4, CGFloat(level) * 48)
                Capsule()
                    .fill(color(for: level))
                    .frame(width: 6, height: h)
            }
            Spacer()
            if active {
                Label("录音中", systemImage: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(height: 52, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: bars)
    }

    private func color(for level: Float) -> Color {
        if level > 0.5 { return .primary.opacity(0.85) }
        if level > 0.15 { return .secondary }
        return Color.secondary.opacity(0.35)
    }
}
