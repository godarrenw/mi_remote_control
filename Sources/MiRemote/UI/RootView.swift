import SwiftUI
import AppKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case mapping, profile, voice, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mapping: return "按键映射"
        case .profile: return "场景配置"
        case .voice:   return "语音"
        case .general: return "通用"
        }
    }
    var icon: String {
        switch self {
        case .mapping: return "dpad"
        case .profile: return "rectangle.stack"
        case .voice:   return "mic"
        case .general: return "gearshape"
        }
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem = .mapping
    @State private var showOnboarding = false
    @State private var showHealthCheck = false
    @State private var showReauth = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // 侧栏头部
                HStack(spacing: Spacing.intra) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                                                 startPoint: .top, endPoint: .bottom))
                        Image(systemName: "av.remote")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("遥控器控制台").font(.headline)
                        HStack(spacing: 4) {
                            Text("MI RC 2 Pro").font(.caption2).foregroundStyle(.secondary)
                            if let pct = model.batteryPercent {
                                Image(systemName: batterySymbol(pct)).font(.caption2).foregroundStyle(.secondary)
                                Text("\(pct)%").font(.caption2).foregroundStyle(.secondary)
                            } else if model.connected {
                                ProgressView().controlSize(.mini)
                                Text("正在读取电量…").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "battery.0percent").font(.caption2).foregroundStyle(.tertiary)
                                Text("电量待连接").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.rowH - 2)
                .padding(.vertical, Spacing.rowH)

                List(SidebarItem.allCases, selection: $selection) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            switch selection {
            case .mapping: MappingPage()
            case .profile: ProfilePage(selection: $selection)
            case .voice:   VoicePage()
            case .general: GeneralPage(onShowOnboarding: { showOnboarding = true },
                                       onShowHealthCheck: { showHealthCheck = true })
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $showOnboarding) { OnboardingWizard() }
        .sheet(isPresented: $showHealthCheck) { HealthCheckSheet() }
        .sheet(isPresented: $showReauth) { ReauthSheet() }
        .onAppear {
            if !model.hasCompletedOnboarding {
                showOnboarding = true
            } else if !PermissionMemory.lostPermissions().isEmpty {
                // 升级失权（上次有授权、这次没了）→ 自动弹精简重授权 sheet
                showReauth = true
            }
            PermissionMemory.snapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .miremoteShowHealthCheck)) { _ in
            showHealthCheck = true
        }
    }

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case 0..<15:  return "battery.0percent"
        case 15..<40: return "battery.25percent"
        case 40..<65: return "battery.50percent"
        case 65..<90: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }
}

extension Notification.Name {
    static let miremoteShowHealthCheck = Notification.Name("com.miremote.showHealthCheck")
}
