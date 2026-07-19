import SwiftUI
import AppKit

// MARK: - 录制式快捷键捕获（NSEvent 本地监听，左右修饰键靠设备位区分）

/// keyCode → 键名（ActionRunner.keyCodes 的反查表；重名取规范名）。
enum KeyNameLookup {
    static let canonical: [CGKeyCode: String] = {
        // 优先级：先注册的规范名不被别名覆盖
        let aliasLosers: Set<String> = ["enter", "backspace", "esc", "backtick"]
        var map: [CGKeyCode: String] = [:]
        for (name, code) in ActionRunner.keyCodes where !aliasLosers.contains(name) {
            if map[code] == nil { map[code] = name }
        }
        return map
    }()

    /// NSEvent.modifierFlags 原始值内含 IOKit 设备位，据此区分左右修饰键。
    static func mods(fromRawFlags raw: UInt64) -> [String] {
        ActionRunner.modifiers.compactMap { name, m in
            (raw & m.deviceBit) != 0 ? name : nil
        }.sorted()
    }
}

/// 危险/环路组合黄字提示（不阻止）。
func shortcutWarning(key: String, mods: [String]) -> String? {
    let hasCmd = mods.contains { $0.hasSuffix("cmd") }
    if hasCmd && key == "q" { return "⌘Q 会退出前台 App，确定？" }
    if hasCmd && key == "w" { return "⌘W 会关闭前台窗口，确定？" }
    return nil
}

/// 录制快捷键 sheet：待录制 → 录制中（接管键盘）→ 已捕获（确认/重录）。
/// 已拍板：Esc = 录入 Esc 键；取消用右上角 X 按钮。
@MainActor
struct ShortcutRecorderSheet: View {
    var onConfirm: (Action) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var recording = false
    @State private var captured: (key: String, mods: [String])?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("录制快捷键").font(.headline)
                Spacer()
                Button {
                    stopMonitor()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消录制")
            }

            if let cap = captured {
                Text(ActionSummary.keyStrokeSummary(key: cap.key, mods: cap.mods))
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.vertical, 6)
                if let warn = shortcutWarning(key: cap.key, mods: cap.mods) {
                    Text(warn).font(.caption).foregroundStyle(.yellow)
                }
                HStack {
                    Button("↻ 重录") {
                        captured = nil
                        startMonitor()
                    }
                    Button("✓ 确认") {
                        stopMonitor()
                        onConfirm(.keyStroke(key: cap.key, mods: cap.mods))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if recording {
                Text("按下快捷键…")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 10)
                Text("直接按下真实组合键，左右修饰键自动区分；Esc 也会被录入，取消请点右上角 ✕")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button("点此录制快捷键") { startMonitor() }
                    .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { startMonitor() }
        .onDisappear { stopMonitor() }
    }

    private func startMonitor() {
        guard monitor == nil else { recording = true; return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let code = CGKeyCode(ev.keyCode)
            guard let name = KeyNameLookup.canonical[code] else { return nil } // 未知键吞掉
            let mods = KeyNameLookup.mods(fromRawFlags: UInt64(ev.modifierFlags.rawValue))
            captured = (name, mods)
            recording = false
            stopMonitor()
            return nil  // 吞掉，不透传给系统
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

// MARK: - ActionPicker（核心复用控件）

/// 把 Action? 编辑成具体动作。外观=macOS 下拉按钮；一级选类型，二级按需弹 sheet/面板。
@MainActor
struct ActionPicker: View {
    var action: Action?
    var onChange: (Action?) -> Void

    @State private var showRecorder = false
    @State private var showShell = false
    @State private var shellText = ""

    var body: some View {
        Menu {
            Button("无") { onChange(nil) }
            Button("发送按键…") { showRecorder = true }
            Menu("系统功能") {
                ForEach(ActionSummary.systemNames, id: \.value) { item in
                    Button(item.display) { onChange(.system(item.value)) }
                }
            }
            Button("打开应用…") { pickApp() }
            Button("运行 Shell…") {
                if case .shell(let cmd)? = action { shellText = cmd } else { shellText = "" }
                showShell = true
            }
            Button("语音输入") { onChange(.voice) }
            Menu("临时进入层") {
                ForEach(1...3, id: \.self) { n in
                    Button("层 \(n)") { onChange(.layerMomentary(n)) }
                }
            }
            Menu("锁定/切换层") {
                ForEach(1...3, id: \.self) { n in
                    Button("层 \(n)") { onChange(.layerToggle(n)) }
                }
            }
        } label: {
            Text(ActionSummary.describe(action))
                .lineLimit(1)
                .frame(minWidth: 130, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $showRecorder) {
            ShortcutRecorderSheet { onChange($0) }
        }
        .sheet(isPresented: $showShell) {
            VStack(alignment: .leading, spacing: 12) {
                Text("运行 Shell 命令").font(.headline)
                TextField("命令（/bin/zsh -c）", text: $shellText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                HStack {
                    Spacer()
                    Button("取消") { showShell = false }
                    Button("确定") {
                        onChange(.shell(shellText))
                        showShell = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(shellText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.message = "选择要打开的应用"
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url)?.bundleIdentifier {
            onChange(.openApp(bundle))
        }
    }
}
