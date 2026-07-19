import SwiftUI
import AppKit
import CoreBluetooth

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
                        RoundedRectangle(cornerRadius: Radius.badge)
                            .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                                                 startPoint: .top, endPoint: .bottom))
                        Image(systemName: "av.remote")
                            .font(.title3.weight(.medium))
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
            let lostPermissions = PermissionMemory.lostPermissions()
            // 每次进程启动都按当前真实权限重检。完成过向导只代表用户走完流程，
            // 不能掩盖后来拒绝/撤销/签名变化导致的失权。
            // 已完成过首启但 AX/输入监控失权时优先走精简重授权，不重复 BlackHole/配对。
            if PermissionGate.shouldUseReauth(
                hasCompletedOnboarding: model.hasCompletedOnboarding,
                bluetooth: CBCentralManager.authorization,
                lostCorePermissions: lostPermissions) {
                showReauth = true
            } else if PermissionGate.needsOnboarding(
                hasCompletedOnboarding: model.hasCompletedOnboarding,
                bluetooth: CBCentralManager.authorization,
                accessibility: EnvironmentCheck.accessibility().state,
                inputMonitoring: EnvironmentCheck.inputMonitoring().state) {
                showOnboarding = true
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

/// 启动权限门槛的纯判定，避免 UI 生命周期把「向导已完成」误当成「权限仍有效」。
enum PermissionGate {
    static func shouldUseReauth(hasCompletedOnboarding: Bool,
                                bluetooth: CBManagerAuthorization,
                                lostCorePermissions: [String]) -> Bool {
        hasCompletedOnboarding && bluetooth == .allowedAlways && !lostCorePermissions.isEmpty
    }

    static func needsOnboarding(hasCompletedOnboarding: Bool,
                                bluetooth: CBManagerAuthorization,
                                accessibility: EnvCheckState,
                                inputMonitoring: EnvCheckState) -> Bool {
        !hasCompletedOnboarding
            || bluetooth != .allowedAlways
            || accessibility != .granted
            || inputMonitoring != .granted
    }
}

extension Notification.Name {
    static let miremoteShowHealthCheck = Notification.Name("com.miremote.showHealthCheck")
}
