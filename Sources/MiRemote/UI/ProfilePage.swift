import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct ProfilePage: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem
    @State private var showAddApp = false
    @State private var showPresets = false
    @State private var detailProfile: ProfileDetailSelection?
    @State private var hoveredProfile: String?

    private var overlayProfiles: [String] {
        model.config.profiles.keys.filter { $0 != "global" }.sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                PageHeader(title: "场景配置",
                           subtitle: "按前台 App 自动切换按键映射。未单独配置的键继承全局默认。")

                SettingsGroup(title: "全局") {
                    Button {
                        detailProfile = ProfileDetailSelection(id: "global")
                    } label: {
                        SettingsRow(icon: "globe", title: "全局默认（Global）",
                                    subtitle: "适用于所有未单独配置的 App") {
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }

                SettingsGroup(title: "按 App 覆盖") {
                    if overlayProfiles.isEmpty {
                        Text("暂无 App 专用按键方案。点下方按钮添加，或从预设库一键套用。")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    ForEach(Array(overlayProfiles.enumerated()), id: \.element) { idx, bundle in
                        if idx != 0 { RowDivider() }
                        profileRow(bundle)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        showAddApp = true
                    } label: {
                        Label("从运行中的 App 添加", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("导入预设") { showPresets = true }

                    Button("导入 JSON 文件") { importJSON() }
                    Button("导出 JSON") { exportJSON() }

                    if model.presetUndoSnapshot != nil {
                        Button("撤销本次套用") { model.undoPresetApply() }
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(Spacing.page)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showAddApp) { AddRunningAppSheet() }
        .sheet(isPresented: $showPresets) { PresetLibrarySheet() }
        .sheet(item: $detailProfile) { selected in
            MappingDetailView(config: model.config, profile: selected.id,
                              onEdit: {
                                  detailProfile = nil
                                  model.currentProfile = selected.id
                                  selection = .mapping
                              })
                .frame(width: 900, height: 610)
        }
    }

    @ViewBuilder
    private func profileRow(_ bundle: String) -> some View {
        let overrides = model.config.profiles[bundle] ?? [:]
        // 整行可点进详情；删除只在 hover 时出现（系统设置语汇：行尾只留 chevron），也可右键删除
        HStack(spacing: Spacing.intra) {
            appIcon(bundle)
            VStack(alignment: .leading, spacing: 1) {
                Text(profileDisplayName(bundle)).font(.body)
                Text(overrides.isEmpty ? "全部继承全局" : "已覆盖 \(overrides.count) 个键 · 其余继承全局")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hoveredProfile == bundle {
                Button {
                    removeProfile(bundle)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary).font(.caption)
                }
                .buttonStyle(.plain)
                .help("删除该 App 专用方案")
                .transition(.opacity)
            }
            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, Spacing.rowH)
        .padding(.vertical, Spacing.rowV)
        .frame(minHeight: Spacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { detailProfile = ProfileDetailSelection(id: bundle) }
        .onHover { hovering in
            withAnimation(Motion.select) { hoveredProfile = hovering ? bundle : nil }
        }
        .contextMenu {
            Button("查看详情") { detailProfile = ProfileDetailSelection(id: bundle) }
            Button("删除该 App 专用方案", role: .destructive) { removeProfile(bundle) }
        }
    }

    private func removeProfile(_ bundle: String) {
        model.config.profiles.removeValue(forKey: bundle)
        if model.currentProfile == bundle { model.currentProfile = "global" }
        model.saveConfig()
    }

    private func appIcon(_ bundle: String) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 24, height: 24)
            } else {
                Text(String(profileDisplayName(bundle).prefix(2)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择 MiRemote 映射配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try JSONDecoder().decode(MappingConfig.self, from: Data(contentsOf: url))
            guard (1...MappingConfig.currentVersion).contains(imported.version) else {
                throw NSError(domain: "MiRemote", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "不支持配置版本 \(imported.version)，当前最高支持版本 \(MappingConfig.currentVersion)"])
            }
            model.config = migrateConfigIfNeeded(imported)
            if model.config.profiles["global"] == nil { model.config.profiles["global"] = [:] }
            model.currentProfile = "global"
            model.saveConfig()
        } catch {
            showError(title: "无法导入配置", message: error.localizedDescription)
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MiRemote-config.json"
        panel.message = "导出当前全部映射与 Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ConfigStore.save(model.config, to: url) else {
            showError(title: "无法导出配置", message: "请检查目标文件夹权限后重试。")
            return
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private struct ProfileDetailSelection: Identifiable {
    let id: String
}

// MARK: - 从运行中的 App 添加

@MainActor
struct AddRunningAppSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var apps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择要添加专用按键方案的 App").font(.headline)
            List(apps, id: \.processIdentifier) { app in
                Button {
                    guard let bundle = app.bundleIdentifier else { return }
                    if model.config.profiles[bundle] == nil {
                        model.config.profiles[bundle] = [:]
                        model.saveConfig()
                    }
                    model.currentProfile = bundle
                    dismiss()
                } label: {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(app.localizedName ?? app.bundleIdentifier ?? "?")
                        Spacer()
                        if model.config.profiles[app.bundleIdentifier ?? ""] != nil {
                            Text("已存在").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 360, height: 300)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
            }
        }
        .padding(16)
    }
}

// MARK: - 预设库 sheet（浏览 / 预览改动 / 冲突处理 / 套用）

@MainActor
struct PresetLibrarySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var previewing: String?    // preset.id
    @State private var appliedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预设库").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            if let msg = appliedMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Presets.all, id: \.id) { preset in
                        presetCard(preset)
                    }
                }
            }
            .frame(width: 480, height: 420)
        }
        .padding(16)
    }

    @ViewBuilder
    private func presetCard(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName).font(.headline)
                    if let bundle = preset.bundleID {
                        Text("建议应用到：\(profileDisplayName(bundle))")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("功能模式 · 适用于所有 App").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(previewing == preset.id ? "收起" : "预览") {
                    previewing = previewing == preset.id ? nil : preset.id
                }
                .controlSize(.small)
                Menu("应用") {
                    Button("仅填空位（推荐，保护已有绑定）") { apply(preset, onlyFillEmpty: true) }
                    Button("全部覆盖（预设优先）") { apply(preset, onlyFillEmpty: false) }
                }
                .controlSize(.small)
                .fixedSize()
            }
            Text(preset.note).font(.caption).foregroundStyle(.secondary)
            if previewing == preset.id {
                previewTable(preset)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    /// 改动清单表：键 / 当前绑定 / 预设将改成；冲突行标黄。
    @ViewBuilder
    private func previewTable(_ preset: Preset) -> some View {
        let target = preset.bundleID ?? "global"
        let existing = model.config.profiles[target] ?? [:]
        VStack(spacing: 4) {
            ForEach(preset.bindings.keys.sorted(), id: \.self) { keyName in
                let presetBinding = preset.bindings[keyName]!
                let curBinding = existing[keyName]
                let rows = diffRows(preset: presetBinding, current: curBinding)
                ForEach(rows, id: \.slot) { row in
                    HStack {
                        Text("\(RemoteKey(rawValue: keyName).map(KeyDisplay.name) ?? keyName) · \(row.slot)")
                            .font(.caption)
                            .frame(width: 150, alignment: .leading)
                        Text(row.current ?? "—")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(row.new)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(row.conflict ? Color.yellow.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
            }
        }
        .padding(.top, 4)
    }

    private struct DiffRow { let slot: String; let current: String?; let new: String; let conflict: Bool }

    private func diffRows(preset: KeyBinding, current: KeyBinding?) -> [DiffRow] {
        var rows: [DiffRow] = []
        func add(_ slot: String, _ p: Action?, _ c: Action?) {
            guard let p else { return }
            rows.append(DiffRow(slot: slot,
                                current: c.map { ActionSummary.describe($0) },
                                new: ActionSummary.describe(p),
                                conflict: c != nil && c != p))
        }
        add("短按", preset.tap, current?.tap)
        add("长按", preset.hold, current?.hold)
        add("双击", preset.double, current?.double)
        for (dir, act) in preset.gesture ?? [:] {
            add("手势·\(dir)", act, current?.gesture?[dir])
        }
        for (layer, act) in (preset.layers ?? [:]).sorted(by: { $0.key < $1.key }) {
            add(modeDisplayName(Int(layer) ?? 0), act, current?.layers?[layer])
        }
        return rows
    }

    private func apply(_ preset: Preset, onlyFillEmpty: Bool) {
        model.applyPreset(preset, to: preset.bundleID, onlyFillEmpty: onlyFillEmpty)
        appliedMessage = "已套用「\(preset.displayName)」，可在 Profile 页撤销本次套用"
    }
}
