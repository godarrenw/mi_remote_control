import Foundation
import ApplicationServices
import IOKit.hid

/// M6 环境检测纯 API（无 UI），供 M5 首次启动向导（DESIGN §7 三步向导）逐项调用。
///
/// 每项检测返回 `EnvCheckResult`：状态 + 可跳转的系统设置面板/官方下载页 URL。
/// 所有检测均为只读、快速、可重复调用，不触发权限弹窗、不修改系统状态。
enum EnvCheckState {
    case granted   // 已授权 / 已就绪
    case denied    // 明确未授权 / 未就绪
    case unknown   // 系统未返回明确结果（如从未请求过输入监控）
}

struct EnvCheckResult {
    let state: EnvCheckState
    /// 引导用户处理该项的 URL：
    /// 权限项 → 系统设置对应面板（x-apple.systempreferences:...）；
    /// BlackHole → 官方下载页。
    let guideURL: URL?
}

enum EnvironmentCheck {

    // MARK: - 辅助功能（Accessibility）

    /// `AXIsProcessTrusted`：不弹窗，只查询当前进程是否在辅助功能列表。
    static func accessibility() -> EnvCheckResult {
        EnvCheckResult(
            state: AXIsProcessTrusted() ? .granted : .denied,
            guideURL: URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
    }

    /// 由用户点击授权按钮后调用：让系统登记当前 App 并显示原生辅助功能授权提示。
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 输入监控（Input Monitoring）

    /// `IOHIDCheckAccess(listenEvent)`：只读查询，不触发授权弹窗。
    /// 系统从未记录过本进程请求时返回 unknown。
    static func inputMonitoring() -> EnvCheckResult {
        let state: EnvCheckState
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: state = .granted
        case kIOHIDAccessTypeDenied:  state = .denied
        default:                      state = .unknown
        }
        return EnvCheckResult(
            state: state,
            guideURL: URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"))
    }

    /// 由用户点击授权按钮后调用：请求系统登记输入监控权限。
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - BlackHole 虚拟声卡

    static let blackHoleDriverPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"

    /// 检测 BlackHole 2ch 驱动是否已安装（语音模式 A 依赖）。
    ///
    /// v1 不内嵌 BlackHole 安装包（避免 GPLv3 随包分发的打包合规复杂度），
    /// 只做检测 + 提供官方下载页 URL 由用户自行安装。
    /// DESIGN §7 的"内置安装包 + 重启 coreaudiod"一键安装方案留 v2 实现。
    static func blackHole() -> EnvCheckResult {
        let installed = FileManager.default.fileExists(atPath: blackHoleDriverPath)
        return EnvCheckResult(
            state: installed ? .granted : .denied,
            guideURL: URL(string: "https://existential.audio/blackhole/"))
    }

    // MARK: - 遥控器连接

    /// 只读枚举 IOHID 设备集，匹配小米遥控器 VID/PID（与 HIDEngine 一致）。
    /// 注意：只 create + setDeviceMatching + copyDevices，**不调用 IOHIDManagerOpen**——
    /// 枚举 device set 不需要 open，open 会触发输入监控权限判定且可能与
    /// 主 HIDEngine 的会话相互干扰。用完即弃（ARC 释放，无需 close）。
    static func remoteConnected(vendorID: Int = RemoteIdentity.vendorID,
                                productID: Int = RemoteIdentity.productID) -> EnvCheckResult {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ] as CFDictionary)
        let count = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
        return EnvCheckResult(
            state: count > 0 ? .granted : .denied,
            guideURL: URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings"))
    }
}
