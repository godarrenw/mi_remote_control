import SwiftUI

@MainActor
struct GeneralPage: View {
    @EnvironmentObject var model: AppModel
    var onShowOnboarding: () -> Void
    var onShowHealthCheck: () -> Void

    @State private var loginItemOn = false
    @State private var confirmHideStatusItem = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("通用").font(.system(size: 22, weight: .bold))
                    Text("调整触发阈值、开机行为与提示反馈。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsGroup(title: "启动与显示") {
                    SettingsRow(icon: "power.circle", title: "登录时启动", subtitle: nil) {
                        Toggle("", isOn: $loginItemOn)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: loginItemOn) { _, new in
                                _ = model.loginItems.setEnabled(new)
                            }
                    }
                    RowDivider()
                    SettingsRow(icon: "menubar.rectangle", title: "显示菜单栏图标",
                                subtitle: "关闭后仅通过屏幕角标反馈状态") {
                        Toggle("", isOn: Binding(
                            get: { model.showStatusItem },
                            set: { new in
                                if !new {
                                    confirmHideStatusItem = true   // 二次确认（ux-flows 附录 23）
                                } else {
                                    model.showStatusItem = true
                                }
                            }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(icon: "speaker.wave.2", title: "功能模式切换提示音", subtitle: "进入或退出第二功能时播放提示") {
                        Toggle("", isOn: $model.feedbackSound).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(icon: "lock.shield", title: "独占按键（Seize）",
                                subtitle: "失败时自动降级为监听 + 事件抑制") {
                        Toggle("", isOn: $model.seizeDevice).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(icon: "questionmark.circle", title: "退出确认",
                                subtitle: "退出前提示「已恢复真实键盘」") {
                        Toggle("", isOn: $model.exitConfirm).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(icon: "delete.left", title: "长按删除：清空输入",
                                subtitle: "默认关闭；开启后长按删除会先全选再删除，短按始终是普通删除") {
                        Toggle("", isOn: Binding(
                            get: { model.config.settings.deleteAllOnHold == true },
                            set: { enabled in
                                model.config.settings.deleteAllOnHold = enabled ? true : nil
                                model.saveConfig()
                            }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                DisclosureGroup {
                    SettingsGroup(title: "触发阈值") {
                        VStack(spacing: 8) {
                            HStack {
                                Text("长按阈值").font(.callout)
                                Slider(value: Binding(
                                    get: { Double(model.config.settings.holdMs) },
                                    set: { model.config.settings.holdMs = Int($0) }),
                                       in: 150...800, step: 50,
                                       onEditingChanged: { editing in if !editing { model.saveConfig() } })
                                Text("\(model.config.settings.holdMs) ms")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                            Divider()
                            HStack {
                                Text("双击窗口").font(.callout)
                                Slider(value: Binding(
                                    get: { Double(model.config.settings.doubleMs) },
                                    set: { model.config.settings.doubleMs = Int($0) }),
                                       in: 0...500, step: 50,
                                       onEditingChanged: { editing in if !editing { model.saveConfig() } })
                                Text(model.config.settings.doubleMs > 0 ? "\(model.config.settings.doubleMs) ms" : "关闭")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                            Text("双击窗口 = 0 关闭双击，短按零延迟触发")
                                .font(.system(size: 10)).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("基础状态为文字输入：方向、确认、删除固定保持原生语义；App 快捷动作仅在第二功能/导航模式或明确组合手势中生效。")
                                .font(.system(size: 10)).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("高级设置").font(.callout)
                }

                SettingsGroup(title: "关于") {
                    SettingsRow(icon: "info.circle", title: "版本", subtitle: nil) {
                        Text("1.0.0 (M5)").font(.caption).foregroundStyle(.secondary)
                    }
                    RowDivider()
                    SettingsRow(icon: "sparkles", title: "重新运行首次启动引导", subtitle: nil) {
                        Button("打开") { onShowOnboarding() }.controlSize(.small)
                    }
                    RowDivider()
                    SettingsRow(icon: "stethoscope", title: "一键体检与修复", subtitle: nil) {
                        Button("打开") { onShowHealthCheck() }.controlSize(.small)
                    }
                    RowDivider()
                    SettingsRow(icon: "escape", title: "退出 MiRemote",
                                subtitle: "恢复按键中转后完全退出。点窗口关闭按钮只是转入后台") {
                        Button("退出") { NSApp.terminate(nil) }.controlSize(.small)
                    }
                    RowDivider()
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. 先从菜单栏「退出 MiRemote」——退出时会清空按键中转、恢复真实键盘。直接删 App 可能残留中转污染键盘。")
                            Text("2. 把 MiRemote.app 拖到废纸篓。")
                            Text("3. 可选：删除配置目录 ~/Library/Application Support/MiRemote/。")
                            HStack {
                                Button("复制清理命令") {
                                    let cmd = "rm -rf ~/Library/Application\\ Support/MiRemote"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                }
                                .controlSize(.small)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    } label: {
                        Label("彻底卸载指引", systemImage: "trash")
                            .font(.callout)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
            .padding(24)
        }
        .onAppear { loginItemOn = model.loginItems.isEnabled }
        .confirmationDialog("关闭菜单栏图标后，只能从启动台/Spotlight 重新打开设置窗口。确定关闭？",
                            isPresented: $confirmHideStatusItem, titleVisibility: .visible) {
            Button("仍要关闭", role: .destructive) { model.showStatusItem = false }
            Button("保留图标", role: .cancel) {}
        }
    }
}
