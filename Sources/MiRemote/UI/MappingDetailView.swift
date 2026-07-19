import AppKit
import SwiftUI

/// Profile 详情页与遥控器速查浮层共用的映射解析，保证两处展示的是实际生效结果。
enum MappingDetailResolver {
    static func binding(in config: MappingConfig, profile: String, key: RemoteKey) -> KeyBinding? {
        let global = config.profiles["global"]?[key.rawValue]
        guard profile != "global", let overlay = config.profiles[profile]?[key.rawValue] else {
            return global
        }
        guard var merged = global else { return overlay }
        if let v = overlay.tap { merged.tap = v }
        if let v = overlay.hold { merged.hold = v }
        if let v = overlay.double { merged.double = v }
        if let values = overlay.gesture {
            var result = merged.gesture ?? [:]
            for (name, action) in values { result[name] = action }
            merged.gesture = result
        }
        if let values = overlay.layers {
            var result = merged.layers ?? [:]
            for (name, action) in values { result[name] = action }
            merged.layers = result
        }
        return merged
    }

    static func ownsOverride(in config: MappingConfig, profile: String, key: RemoteKey) -> Bool {
        profile == "global" || config.profiles[profile]?[key.rawValue] != nil
    }
}

/// 一张能完整看到短按、长按、双击、功能模式和 OK 手势的映射表。
struct MappingDetailView: View {
    let config: MappingConfig
    let profile: String
    var appName: String? = nil
    var isQuickLook = false
    var onEdit: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    private let keys: [RemoteKey] = [
        .up, .down, .left, .right, .ok, .back, .home, .menu, .tv,
        .volUp, .volDown, .voice, .power,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName ?? (profile == "global" ? "全局默认" : profileDisplayName(profile)))
                        .font(.system(size: isQuickLook ? 20 : 18, weight: .bold))
                    Text(profile == "global" ? "所有 App 的基础映射" : "当前实际生效映射 · 未覆盖项继承全局")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isQuickLook {
                    Text("再按主页 / 返回键或 Esc 关闭")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let onEdit {
                    Button("编辑映射", action: onEdit).buttonStyle(.borderedProminent)
                }
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("关闭")
                }
            }

            HStack(spacing: 0) {
                tableHeader("遥控键", width: 116)
                tableHeader("短按", width: 170)
                tableHeader("长按", width: 170)
                tableHeader("双击", width: 150)
                tableHeader("更多", width: nil)
            }
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                        if index > 0 { Divider() }
                        mappingRow(key)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1))

            if isQuickLook {
                Text("长按主页键可随时打开这张表；浮层打开期间遥控键不会触发原动作。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: isQuickLook ? 500 : 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tableHeader(_ title: String, width: CGFloat?) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func mappingRow(_ key: RemoteKey) -> some View {
        let binding = MappingDetailResolver.binding(in: config, profile: profile, key: key)
        let overlay = profile == "global" ? nil : config.profiles[profile]?[key.rawValue]
        return HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 7) {
                Text(KeyDisplay.badge(key)).font(.system(size: 10, weight: .bold))
                    .frame(width: 27, height: 24)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(KeyDisplay.name(key)).font(.caption)
                    if profile != "global" {
                        Text(overlay == nil ? "全部继承" : "含 App 覆盖")
                            .font(.system(size: 9)).foregroundStyle(overlay == nil ? .secondary : Color.accentColor)
                    }
                }
            }
            .frame(width: 116, alignment: .leading)
            actionText(binding?.tap, width: 170, overridden: overlay?.tap != nil)
            actionText(binding?.hold, width: 170, overridden: overlay?.hold != nil)
            actionText(binding?.double, width: 150, overridden: overlay?.double != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(moreSummary(binding))
                    .font(.caption).foregroundStyle(moreSummary(binding) == "—" ? .tertiary : .secondary)
                    .lineLimit(3)
                sourceLabel(overridden: overlay?.gesture != nil || overlay?.layers != nil)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func actionText(_ action: Action?, width: CGFloat, overridden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ActionSummary.describe(action))
                .font(.caption)
                .foregroundStyle(action == nil || action == Action.none ? .tertiary : .primary)
                .lineLimit(2)
            sourceLabel(overridden: overridden)
        }
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder private func sourceLabel(overridden: Bool) -> some View {
        if profile != "global" {
            Text(overridden ? "App 覆盖" : "继承全局")
                .font(.system(size: 9, weight: overridden ? .medium : .regular))
                .foregroundStyle(overridden ? Color.accentColor : .secondary)
        }
    }

    private func moreSummary(_ binding: KeyBinding?) -> String {
        var parts: [String] = []
        if let layers = binding?.layers {
            for (number, action) in layers.sorted(by: { $0.key < $1.key }) {
                let name = Int(number).map(modeDisplayName) ?? "模式 \(number)"
                parts.append("\(name)：\(ActionSummary.describe(action))")
            }
        }
        if let gestures = binding?.gesture {
            let names = ["up": "↑", "down": "↓", "left": "←", "right": "→"]
            for direction in ["up", "down", "left", "right"] {
                if let action = gestures[direction] {
                    parts.append("按住 OK+\(names[direction]!)：\(ActionSummary.describe(action))")
                }
            }
        }
        return parts.isEmpty ? "—" : parts.joined(separator: "\n")
    }

    @ViewBuilder private var appIcon: some View {
        if profile == "global" {
            Image(systemName: "globe").font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                .frame(width: 38, height: 38)
        } else {
            Image(systemName: "app").font(.title2).foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
        }
    }
}

/// 不抢焦点、跨桌面显示的当前 App 映射速查窗。
@MainActor
final class MappingQuickLookController {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private(set) var isVisible = false

    init(model: AppModel) { self.model = model }

    func setVisible(_ visible: Bool, bundleID: String?, appName: String?) {
        visible ? show(bundleID: bundleID, appName: appName) : hide()
    }

    private func show(bundleID: String?, appName: String?) {
        guard let model else { return }
        let profile = bundleID ?? "global"
        let root = MappingDetailView(config: model.config, profile: profile,
                                     appName: appName, isQuickLook: true,
                                     onClose: nil)
        let host = NSHostingView(rootView: root)
        let p = panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 570),
                                 styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: true)
        p.title = "当前 App 映射速查"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.setContentSize(NSSize(width: 840, height: 570))
        p.center()
        panel = p
        isVisible = true
        p.orderFrontRegardless()
    }

    private func hide() {
        isVisible = false
        panel?.orderOut(nil)
    }
}
