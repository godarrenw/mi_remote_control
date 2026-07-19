import SwiftUI

// MARK: - 一键体检与修复（ux-flows 旅程 6）

@MainActor
struct HealthCheckSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum ItemState { case checking, ok, bad, warn }

    struct Item: Identifiable {
        let id: String
        let name: String
        var state: ItemState = .checking
        var detail: String = ""
        var actionTitle: String?
        var action: (() -> Void)?
    }

    @State private var items: [Item] = []
    @State private var checked = false

    private var problems: Int { items.filter { $0.state == .bad || $0.state == .warn }.count }
    private var permissionsNeedRestart: Bool {
        items.contains { ($0.id == "ax" || $0.id == "im") && $0.state != .ok }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("一键体检与修复").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            // 总结横幅
            if checked {
                if problems == 0 {
                    Label("全部正常", systemImage: "checkmark.seal.fill")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Label("发现 \(problems) 个问题，按右侧按钮逐项处理", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx != 0 { Divider().padding(.leading, 36) }
                    HStack(spacing: 10) {
                        stateIcon(item.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.callout)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if item.state != .ok, let title = item.actionTitle, let act = item.action {
                            Button(title) { act() }.controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

            HStack {
                Button("重新体检") { runChecks() }
                Spacer()
                if permissionsNeedRestart {
                    Button("退出并重新打开") { AppLifecycle.quitAndRelaunch(model) }
                        .buttonStyle(.borderedProminent)
                        .help("授权后重启 App，让新权限进入按键通道")
                }
                Button("尝试自动修复") {
                    let msg = model.runHealthRepair()
                    log("体检修复: \(msg)")
                    runChecks()
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { runChecks() }
    }

    @ViewBuilder
    private func stateIcon(_ s: ItemState) -> some View {
        switch s {
        case .checking: ProgressView().controlSize(.small).frame(width: 20)
        case .ok:   Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 20)
        case .bad:  Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: 20)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).frame(width: 20)
        }
    }

    private func runChecks() {
        checked = false
        items = [
            Item(id: "ax", name: "辅助功能权限"),
            Item(id: "im", name: "输入监控权限"),
            Item(id: "remote", name: "遥控器连接"),
            Item(id: "blackhole", name: "BlackHole 虚拟声卡"),
            Item(id: "tap", name: "事件注入通道"),
            Item(id: "config", name: "配置文件"),
        ]
        // 逐项点亮（有节奏，让用户感到"在认真检查"）
        let checks: [(String, () -> (ItemState, String, String?, (() -> Void)?))] = [
            ("ax", {
                let r = EnvironmentCheck.accessibility()
                return r.state == .granted
                    ? (.ok, "", nil, nil)
                    : (.bad, "按键无法注入。去系统设置勾选 MiRemote", "去授权",
                       { if let u = r.guideURL { NSWorkspace.shared.open(u) } })
            }),
            ("im", {
                let r = EnvironmentCheck.inputMonitoring()
                return r.state == .granted
                    ? (.ok, "", nil, nil)
                    : (.bad, "无法读取遥控器按键。去系统设置勾选 MiRemote", "去授权",
                       { if let u = r.guideURL { NSWorkspace.shared.open(u) } })
            }),
            ("remote", {
                let r = EnvironmentCheck.remoteConnected()
                return r.state == .granted
                    ? (.ok, "", nil, nil)
                    : (.bad, "检查电量、靠近 Mac，或在蓝牙面板重连", "打开蓝牙设置",
                       { if let u = r.guideURL { NSWorkspace.shared.open(u) } })
            }),
            ("blackhole", {
                let r = EnvironmentCheck.blackHole()
                return r.state == .granted
                    ? (.ok, "", nil, nil)
                    : (.warn, "遥控器麦克风模式不可用（不用语音可忽略）", "去下载",
                       { if let u = r.guideURL { NSWorkspace.shared.open(u) } })
            }),
            ("tap", { [weak model] in
                guard let model, let services = model.services, services.started else {
                    return (.warn, "引擎未运行（预览模式）", nil, nil)
                }
                return model.degraded
                    ? (.bad, "按键注入通道已断开", "重建通道", { services.reinstallMapping() })
                    : (.ok, "", nil, nil)
            }),
            ("config", { [weak model] in
                guard let model else { return (.warn, "", nil, nil) }
                if !FileManager.default.fileExists(atPath: model.configURL.path) {
                    return (.warn, "配置文件不存在，将在首次修改时生成", nil, nil)
                }
                if ConfigStore.load(from: model.configURL) != nil {
                    return (.ok, "", nil, nil)
                }
                return (.bad, "配置文件解析失败，当前使用默认配置", "恢复默认配置（备份旧文件）", {
                    let broken = model.configURL.deletingLastPathComponent()
                        .appendingPathComponent("config.broken.json")
                    try? FileManager.default.removeItem(at: broken)
                    try? FileManager.default.moveItem(at: model.configURL, to: broken)
                    model.config = defaultConfig()
                    model.saveConfig()
                })
            }),
        ]
        for (i, (id, check)) in checks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(i)) {
                let (state, detail, actionTitle, action) = check()
                if let idx = items.firstIndex(where: { $0.id == id }) {
                    items[idx].state = state
                    items[idx].detail = detail
                    items[idx].actionTitle = actionTitle
                    items[idx].action = action
                }
                if i == checks.count - 1 { checked = true }
            }
        }
    }
}
