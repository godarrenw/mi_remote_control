import SwiftUI

@MainActor
struct VoicePage: View {
    @EnvironmentObject var model: AppModel

    private var blackHoleInstalled: Bool {
        EnvironmentCheck.blackHole().state == .granted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("语音").font(.system(size: 22, weight: .bold))
                    Text("选择语音输入的音频来源，语音识别文字工作交给豆包输入法完成。")
                        .font(.caption).foregroundStyle(.secondary)
                }

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
                            Text("输入增益").font(.callout)
                            Slider(value: $model.voiceGainDb, in: -12...12, step: 1)
                            Text(String(format: "%+.0f dB", model.voiceGainDb))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                        Text("增益改动在下次语音会话生效")
                            .font(.system(size: 10)).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                    .padding(14)
                }
            }
            .padding(24)
        }
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
        if level > 0.5 { return Color(white: 0.25) }
        if level > 0.15 { return Color(white: 0.45) }
        return Color(white: 0.75)
    }
}
