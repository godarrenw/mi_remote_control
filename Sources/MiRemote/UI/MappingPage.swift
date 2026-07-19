import SwiftUI

// MARK: - 通用卡片组件（复刻 macOS 系统设置分组外观）

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var icon: String
    var iconColor: Color = .accentColor
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 44)
    }
}

// MARK: - 映射页

@MainActor
struct MappingPage: View {
    @EnvironmentObject var model: AppModel
    @State private var showKeyLearn = false
    @State private var showSaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.activeLayer != 0 {
                    Label("已开启：\(modeDisplayName(model.activeLayer))（同一按键现在使用第二功能）", systemImage: "switch.2")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                HStack(alignment: .top, spacing: 28) {
                    remotePanel
                    keyEditor
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showKeyLearn) { KeyLearnSheet() }
        .onChange(of: model.savedTick) {
            withAnimation(.easeIn(duration: 0.1)) { showSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation(.easeOut(duration: 0.4)) { showSaved = false }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("按键映射").font(.system(size: 22, weight: .bold))
                Text(model.currentProfile == "global"
                     ? "点击左侧遥控器上的按键，编辑它的触发动作。改动即时保存并生效。"
                     : "正在编辑 profile「\(profileDisplayName(model.currentProfile))」的覆盖绑定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showSaved {
                Label("已保存", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Button {
                showKeyLearn = true
            } label: {
                Label("识别按键", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("按一下遥控器上的键，识别它是哪个键")
        }
    }

    private var remotePanel: some View {
        VStack(spacing: 10) {
            RemoteDiagram(selected: $model.selectedKey,
                          flashing: model.lastPressedKey,
                          connected: model.connected)
                .frame(width: 190)
            Text("深色圆键为遥控器实体按键位置示意，选中的按键以系统蓝细描边高亮")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)
                .frame(width: 190)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: KeyEditor

    private var keyEditor: some View {
        let key = model.selectedKey
        let binding = model.binding(for: key)
        return VStack(alignment: .leading, spacing: 16) {
            // 头部
            HStack(spacing: 10) {
                Text(KeyDisplay.badge(key))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(KeyDisplay.name(key)).font(.system(size: 15, weight: .semibold))
                    Text(KeyDisplay.usage(key)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            // 分组 A：触发方式
            SettingsGroup(title: "触发方式") {
                SettingsRow(icon: "checkmark", iconColor: .blue, title: "短按", subtitle: "松开时立即触发") {
                    ActionPicker(action: binding.tap) { new in
                        model.updateBinding(for: key) { $0.tap = new }
                    }
                }
                RowDivider()
                SettingsRow(icon: "clock", iconColor: .orange, title: "长按",
                            subtitle: "超过 \(model.config.settings.holdMs) ms 触发") {
                    ActionPicker(action: binding.hold) { new in
                        model.updateBinding(for: key) { $0.hold = new }
                    }
                }
                RowDivider()
                SettingsRow(icon: "ellipsis", iconColor: .purple, title: "双击",
                            subtitle: model.config.settings.doubleMs > 0
                                ? "\(model.config.settings.doubleMs)ms 窗口内连按两次"
                                : "已关闭（在通用页开启）") {
                    ActionPicker(action: binding.double) { new in
                        model.updateBinding(for: key) { $0.double = new }
                    }
                }
            }

            // 分组 B：手势（仅 OK）
            if key == .ok {
                SettingsGroup(title: "手势（按住 OK + 方向键）") {
                    ForEach(Array(zip(["up", "down", "left", "right"],
                                      ["arrow.up", "arrow.down", "arrow.left", "arrow.right"])), id: \.0) { dir, sym in
                        if dir != "up" { RowDivider() }
                        SettingsRow(icon: sym, iconColor: .teal, title: gestureTitle(dir)) {
                            ActionPicker(action: binding.gesture?[dir]) { new in
                                model.updateBinding(for: key) { b in
                                    var g = b.gesture ?? [:]
                                    if let new { g[dir] = new } else { g.removeValue(forKey: dir) }
                                    b.gesture = g.isEmpty ? nil : g
                                }
                            }
                        }
                    }
                }
            }

            // 分组 C：第二功能模式（底层仍沿用 layer 配置格式，UI 不暴露术语）
            DisclosureGroup {
                Text("功能模式类似遥控器的 Fn：按住 OK 使用快捷控制（切 App、桌面空间等）；单击 TV 进出 App 控制模式（批准、拒绝、切换 agent，屏幕角落有键位提示）。")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                SettingsGroup(title: "模式开启时，这个键执行") {
                    ForEach(1...3, id: \.self) { layer in
                        if layer != 1 { RowDivider() }
                        SettingsRow(icon: "switch.2", iconColor: .blue, title: modeDisplayName(layer)) {
                            ActionPicker(action: binding.layers?["\(layer)"]) { new in
                                model.updateBinding(for: key) { b in
                                    var l = b.layers ?? [:]
                                    if let new { l["\(layer)"] = new } else { l.removeValue(forKey: "\(layer)") }
                                    b.layers = l.isEmpty ? nil : l
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("第二功能模式（高级）").font(.callout)
            }

            Text("绑定组合键可点击「录制快捷键」。如果不确定当前状态，可再按一下 TV 键退出 App 控制模式。")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gestureTitle(_ dir: String) -> String {
        ["up": "上", "down": "下", "left": "左", "right": "右"][dir].map { "OK + \($0)" } ?? dir
    }
}

func profileDisplayName(_ bundleID: String) -> String {
    if bundleID == "global" { return "全局默认（Global）" }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path)
    }
    return bundleID
}

// MARK: - 识别按键 sheet（学习模式：显示下一个按下的遥控键）

@MainActor
struct KeyLearnSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var learned: RemoteKey?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("识别按键").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let key = learned {
                VStack(spacing: 6) {
                    Text(KeyDisplay.badge(key))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(KeyDisplay.name(key)).font(.system(size: 15, weight: .semibold))
                    Text(KeyDisplay.usage(key)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("再识别一个") { learned = nil }
                    Button("编辑此键") {
                        model.selectedKey = key
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if model.connected || model.services?.started == true {
                ProgressView().controlSize(.small)
                Text("请按一下遥控器上的任意键…")
                    .font(.callout)
                Text("识别期间按键不触发映射之外的额外动作")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("引擎未运行（预览模式或遥控器未连接），无法识别").font(.callout)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onChange(of: model.lastPressedKey) { _, new in
            if let new, learned == nil { learned = new }
        }
    }
}
