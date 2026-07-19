import Foundation
import ServiceManagement
import os

// MARK: - 健康状态模型（稳定性专项）

/// 汇总健康状态。未来 M5 菜单栏图标变色用 onChange 回调，现在先落日志。
enum HealthState: Equatable {
    case healthy
    case degraded([String])   // 部分功能受损（原因列表），核心仍可用
    case broken([String])     // 核心功能失效，需用户处理或等待自愈
}

/// 四项健康源的快照（纯值类型，computeOverall 为纯函数，便于 self-test）。
struct HealthSources: Equatable {
    /// 按键模式（--keys）是否启用：未启用时 tap/映射两项不参与判定。
    var keysEnabled = false
    /// BLE 连接态（ATVVBridge delegate 事件经 main 喂入）。
    var bleConnected = false
    /// CGEventTap 存活（TapEngine 的 hidSeizeState 回调喂入，30s 健康检查已在 TapEngine 内）。
    var tapAlive = false
    /// hidutil 中转映射在位（周期 --get 校验）。
    var mappingInstalled = false
    /// 辅助功能权限（EnvironmentCheck 周期查询）。
    var accessibilityGranted = true
    /// 输入监控权限（denied 才算撤销；unknown 不降级——系统可能从未记录过请求）。
    var inputMonitoringGranted = true
}

// MARK: - 一键体检与修复

struct RepairItem {
    enum Status {
        case ok         // 检查通过
        case repaired   // 发现问题且已自动修复
        case info       // 提示性信息，不影响退出码
        case needsUser  // 修不了，需要用户按指引处理
        case failed     // 自动修复尝试失败
    }
    let name: String
    let status: Status
    /// 人话说明/指引文本（needsUser 时告诉用户去哪、做什么）。
    let message: String
    /// 权限类跳系统设置面板，BlackHole 跳官方下载页（复用 EnvironmentCheck 的 URL）。
    let guideURL: URL?
}

struct RepairReport {
    let items: [RepairItem]
    /// 有需用户处理项（含自动修复失败）→ true。
    var needsUser: Bool {
        items.contains { $0.status == .needsUser || $0.status == .failed }
    }
    var exitCode: Int32 { needsUser ? 1 : 0 }

    /// 人话中文逐行输出（--doctor 与未来 M5「错误维修」按钮共用）。
    func lines() -> [String] {
        items.map { item in
            let tag: String
            switch item.status {
            case .ok:        tag = "[通过]"
            case .repaired:  tag = "[已修复]"
            case .info:      tag = "[提示]"
            case .needsUser: tag = "[需处理]"
            case .failed:    tag = "[失败]"
            }
            var line = "\(tag) \(item.name)：\(item.message)"
            if let url = item.guideURL, item.status == .needsUser || item.status == .failed {
                line += "（\(url.absoluteString)）"
            }
            return line
        }
    }
}

// MARK: - 开机自启（SMAppService 封装）

/// CLI --login-item 参数（M5 的 UI 开关后续调同一 API）。
enum LoginItemCommand: String {
    case on, off, status
}

enum LoginItem {
    /// SMAppService.mainApp 依赖 .app bundle 身份：未打包的裸 CLI 二进制
    /// register() 会失败（launchd 找不到可注册的 bundle）。打包（M6）后生效。
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:          return "已开启"
        case .notRegistered:    return isBundled ? "未开启" : "未开启（当前为未打包 CLI，打包成 .app 后此开关才生效）"
        case .requiresApproval: return "等待用户在 系统设置 → 通用 → 登录项 中批准"
        case .notFound:         return isBundled ? "未注册" : "不可用（当前为未打包 CLI，打包成 .app 后生效）"
        @unknown default:       return "未知状态"
        }
    }

    static func run(_ cmd: LoginItemCommand) -> (message: String, code: Int32) {
        switch cmd {
        case .status:
            return ("开机自启：\(statusDescription())", 0)
        case .on, .off:
            guard isBundled else {
                return ("开机自启需要 .app 包（SMAppService 依赖 bundle 身份）；当前为未打包 CLI 二进制，打包（M6）后此开关生效。", 1)
            }
            do {
                if cmd == .on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                return ("开机自启已\(cmd == .on ? "开启" : "关闭")", 0)
            } catch {
                return ("开机自启设置失败: \(error.localizedDescription)", 1)
            }
        }
    }
}

// MARK: - HealthMonitor

final class HealthMonitor: @unchecked Sendable {

    // MARK: 单实例锁

    /// 持有到进程退出；flock 随进程结束（含 kill -9）由内核自动释放。
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    static func lockFilePath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemote", isDirectory: true)
            .appendingPathComponent("miremote.lock").path
    }

    /// flock 独占非阻塞。返回持有的 fd；拿不到（已有实例/打开失败）返回 nil。
    static func tryLock(path: String) -> Int32? {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// main 最早调用。false = 已有实例在运行（或锁文件不可创建）。
    static func acquireSingleInstanceLock() -> Bool {
        let path = lockFilePath()
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let fd = tryLock(path: path) else { return false }
        lockFD = fd
        return true
    }

    // MARK: 健康状态机

    private struct State {
        var sources = HealthSources()
        var overall: HealthState = .healthy
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 状态变化回调（未来菜单栏图标变色；现在 main 接成日志）。接线期设置，之后只读。
    var onChange: ((HealthState) -> Void)?
    var log: ((String) -> Void)?
    /// 周期检查发现映射缺失时的修复动作（main 接 TapEngine.reinstallMapping）。
    var reinstallMapping: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.miremote.health")

    var overall: HealthState { state.withLock { $0.overall } }

    /// 四源汇聚的纯判定（self-test 直接测这里）。
    static func computeOverall(_ s: HealthSources) -> HealthState {
        var broken: [String] = []
        var degraded: [String] = []
        if !s.accessibilityGranted {
            broken.append("辅助功能权限被撤销（按键映射与豆包触发不可用）")
        }
        if s.keysEnabled && !s.tapAlive {
            broken.append("按键过滤器（CGEventTap）失效（等待自动恢复）")
        }
        if s.keysEnabled && s.tapAlive && !s.mappingInstalled {
            degraded.append("hidutil 中转映射不在位（中转键位暂不生效）")
        }
        if !s.bleConnected {
            degraded.append("遥控器蓝牙未连接（语音不可用，自动重连中）")
        }
        if !s.inputMonitoringGranted {
            degraded.append("输入监控权限未授予（返回键不可用）")
        }
        if !broken.isEmpty { return .broken(broken + degraded) }
        if !degraded.isEmpty { return .degraded(degraded) }
        return .healthy
    }

    static func describe(_ st: HealthState) -> String {
        switch st {
        case .healthy:              return "健康"
        case .degraded(let why):    return "部分受损：\(why.joined(separator: "；"))"
        case .broken(let why):      return "故障：\(why.joined(separator: "；"))"
        }
    }

    private func update(_ mutate: (inout HealthSources) -> Void) {
        let (changed, newState): (Bool, HealthState) = state.withLock { st in
            mutate(&st.sources)
            let next = Self.computeOverall(st.sources)
            let changed = next != st.overall
            st.overall = next
            return (changed, next)
        }
        if changed {
            log?("健康状态 → \(Self.describe(newState))")
            onChange?(newState)
        }
    }

    func setKeysEnabled(_ v: Bool)      { update { $0.keysEnabled = v } }
    func setBLEConnected(_ v: Bool)     { update { $0.bleConnected = v } }
    func setTapAlive(_ v: Bool)         { update { $0.tapAlive = v; $0.mappingInstalled = v } }
    func setMappingInstalled(_ v: Bool) { update { $0.mappingInstalled = v } }

    /// 周期健康检查：权限（60s，被撤时日志+状态回调）+ hidutil 映射在位校验。
    /// 只读操作（hidutil --get / AXIsProcessTrusted / IOHIDCheckAccess），发现映射缺失
    /// 时经 reinstallMapping 闭包委托 TapEngine 幂等重装（tap 未运行时它自己不做事）。
    func startPeriodicChecks(interval: TimeInterval = 60) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval)
        t.setEventHandler { [weak self] in self?.periodicCheck() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func periodicCheck() {
        let ax = EnvironmentCheck.accessibility().state == .granted
        let im = EnvironmentCheck.inputMonitoring().state != .denied
        var mappingMissing = false
        let (keys, tapAlive) = state.withLock { ($0.sources.keysEnabled, $0.sources.tapAlive) }
        if keys, tapAlive, let present = KeyRemapper.mappingPresent() {
            mappingMissing = !present
        }
        update { s in
            s.accessibilityGranted = ax
            s.inputMonitoringGranted = im
            if keys, tapAlive { s.mappingInstalled = !mappingMissing }
        }
        if mappingMissing {
            log?("周期检查：hidutil 中转映射缺失，触发重装")
            reinstallMapping?()
        }
    }

    // MARK: 一键体检与修复

    /// 逐项检查→能修的修→修不了的给指引。standalone（--doctor，无运行中的 tap/BLE）
    /// 只做只读检查 + 残留清理，不安装新映射；运行时（未来 M5 按钮）传入 sources
    /// 快照后残留清理会自动跳过（映射在用不是残留）。
    static func runRepair(runtime: HealthSources? = nil,
                          reinstallMapping: (() -> Void)? = nil) -> RepairReport {
        var items: [RepairItem] = []

        let ax = EnvironmentCheck.accessibility()
        items.append(ax.state == .granted
            ? RepairItem(name: "辅助功能权限", status: .ok, message: "已授权", guideURL: nil)
            : RepairItem(name: "辅助功能权限", status: .needsUser,
                         message: "未授权。前往 系统设置 → 隐私与安全性 → 辅助功能，把 miremote 加入并勾选；重编译后签名变化可能需要重新勾选",
                         guideURL: ax.guideURL))

        let im = EnvironmentCheck.inputMonitoring()
        switch im.state {
        case .granted:
            items.append(RepairItem(name: "输入监控权限", status: .ok, message: "已授权", guideURL: nil))
        case .denied:
            items.append(RepairItem(name: "输入监控权限", status: .needsUser,
                                    message: "未授权。前往 系统设置 → 隐私与安全性 → 输入监控，勾选 miremote（返回键读取需要）",
                                    guideURL: im.guideURL))
        case .unknown:
            items.append(RepairItem(name: "输入监控权限", status: .info,
                                    message: "系统尚未记录授权状态（首次以 --keys 运行时会请求）", guideURL: nil))
        }

        let rc = EnvironmentCheck.remoteConnected()
        items.append(rc.state == .granted
            ? RepairItem(name: "遥控器连接", status: .ok, message: "已连接", guideURL: nil)
            : RepairItem(name: "遥控器连接", status: .needsUser,
                         message: "未检测到遥控器。检查遥控器电量，或在 系统设置 → 蓝牙 中重新连接",
                         guideURL: rc.guideURL))

        let bh = EnvironmentCheck.blackHole()
        items.append(bh.state == .granted
            ? RepairItem(name: "BlackHole 声卡驱动", status: .ok, message: "已安装", guideURL: nil)
            : RepairItem(name: "BlackHole 声卡驱动", status: .needsUser,
                         message: "未安装。语音出字功能需要，请到官网下载 BlackHole 2ch 安装",
                         guideURL: bh.guideURL))

        // hidutil 残留/在位：运行中且 tap 存活 → 映射在用，做「在位校验」（缺失触发重装）；
        // 否则映射本不该存在 → 做「残留清理」。
        if let rt = runtime, rt.keysEnabled, rt.tapAlive {
            switch KeyRemapper.mappingPresent() {
            case true:
                items.append(RepairItem(name: "hidutil 中转映射", status: .ok, message: "在位", guideURL: nil))
            case false:
                if let reinstallMapping {
                    reinstallMapping()
                    items.append(RepairItem(name: "hidutil 中转映射", status: .repaired,
                                            message: "缺失，已触发幂等重装", guideURL: nil))
                } else {
                    items.append(RepairItem(name: "hidutil 中转映射", status: .failed,
                                            message: "缺失且无重装通道，请重启程序", guideURL: nil))
                }
            case nil:
                items.append(RepairItem(name: "hidutil 中转映射", status: .failed,
                                        message: "无法查询设备映射（hidutil 调用失败）", guideURL: nil))
            }
        } else {
            switch KeyRemapper.cleanResidualMapping() {
            case .none:
                items.append(RepairItem(name: "hidutil 映射残留", status: .ok, message: "无残留", guideURL: nil))
            case .cleaned(let n):
                items.append(RepairItem(name: "hidutil 映射残留", status: .repaired,
                                        message: "检测到上次异常退出残留 \(n) 条中转映射，已清理", guideURL: nil))
            case .queryFailed:
                // 遥控器不在场时 hidutil --get 无匹配设备属正常，不算故障。
                items.append(RepairItem(name: "hidutil 映射残留", status: .info,
                                        message: "无法查询（遥控器可能未连接），跳过", guideURL: nil))
            case .cleanFailed:
                items.append(RepairItem(name: "hidutil 映射残留", status: .failed,
                                        message: "检测到残留但清理失败，可手动执行 hidutil property --set 清空后重试", guideURL: nil))
            }
        }

        items.append(RepairItem(name: "开机自启", status: .info,
                                message: LoginItem.statusDescription(), guideURL: nil))
        return RepairReport(items: items)
    }
}
