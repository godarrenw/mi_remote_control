import Foundation
import AppKit

// MiRemote 入口。
// - 纯 CLI 子命令直接执行后退出，不创建 NSApplication。
// - 显式服务参数保持原 CLI 行为。
// - 无参数（或 --ui-preview）进入 SwiftUI App。

// 纯逻辑自检不触碰 BLE/hidutil，允许在 GUI 正在运行时并行执行（打包校验需要）。
let startupArgs = Array(CommandLine.arguments.dropFirst())
if startupArgs == ["--self-test"] { exit(SelfTest.run()) }

// 单实例锁在参数解析【之后】获取：--help / --doctor / --list-audio-devices /
// --login-item status 等只读子命令在解析中就 exit，不与运行中的实例争用
// hidutil / CGEventTap，GUI 在跑时也必须能随时执行（N-29）。

var opts = AppServices.Options()
var cliServiceMode = false
var uiPreview = false

var args = startupArgs
while let argument = args.first {
    args.removeFirst()
    switch argument {
    case "--list-audio-devices":
        AudioBridge.listOutputDevices().forEach { print($0) }
        exit(0)
    case "--self-test":
        exit(SelfTest.run())
    case "--doctor":
        // 体检是 standalone 只读 + 残留清理；但有活实例时 hidutil 中转映射正在使用，
        // 不是残留——探测到活实例就跳过清理，绝不把在用的映射当残留清掉。
        // 用户改过 settings 里的遥控器 VID/PID 时，体检的连接检测/映射匹配也要跟着走。
        if let s = ConfigStore.loadIfExists(at: opts.configPath)?.settings {
            RemoteIdentity.configure(vendorID: s.remoteVendorID, productID: s.remoteProductID)
        }
        let report = HealthMonitor.runRepair(
            skipResidualCleanup: HealthMonitor.anotherInstanceRunning())
        print("MiRemote 一键体检")
        report.lines().forEach { print($0) }
        print(report.needsUser
              ? "—— 存在需要你处理的项，请按上面的指引操作后重跑 --doctor。"
              : "—— 全部检查通过。")
        exit(report.exitCode)
    case "--claude-hooks":
        let sub = args.isEmpty ? "" : args.removeFirst()
        switch sub {
        case "install":
            let result = ClaudeHooks.install()
            print(result.message)
            exit(result.code)
        case "uninstall":
            let result = ClaudeHooks.uninstall()
            print(result.message)
            exit(result.code)
        case "status":
            print(ClaudeHooks.status())
            exit(0)
        default:
            FileHandle.standardError.write("--claude-hooks 需要参数 install|uninstall|status\n".data(using: .utf8)!)
            exit(2)
        }
    case "--login-item":
        guard !args.isEmpty, let command = LoginItemCommand(rawValue: args.removeFirst()) else {
            FileHandle.standardError.write("--login-item 需要参数 on|off|status\n".data(using: .utf8)!)
            exit(2)
        }
        let result = LoginItem.run(command)
        print(result.message)
        exit(result.code)
    case "--output":
        cliServiceMode = true
        opts.outputName = args.isEmpty ? nil : args.removeFirst()
        opts.outputExplicit = true
    case "--wav":
        cliServiceMode = true
        opts.wavPath = args.isEmpty ? nil : args.removeFirst()
    case "--gain":
        opts.gainDB = Double(args.isEmpty ? "0" : args.removeFirst()) ?? 0
    case "--verbose":
        opts.verbose = true
    case "--no-input-switch":
        cliServiceMode = true
        opts.switchInput = false
    case "--doubao":
        cliServiceMode = true
        opts.doubao = true
    case "--keys":
        cliServiceMode = true
        opts.keys = true
    case "--ui-preview":
        uiPreview = true
    case "--config":
        if !args.isEmpty { opts.configPath = args.removeFirst() }
    // 语音触发三件套：既立即生效（--run-action 在参数解析期执行），也记录进 opts，
    // 由 AppServices 按「CLI 覆盖 配置(voiceProfiles.global) 覆盖 内置默认」统一合并。
    case "--trigger-key":
        if !args.isEmpty {
            let value = args.removeFirst()
            VoiceTrigger.config.keyName = value
            opts.cliTriggerKey = value
        }
    case "--trigger-mode":
        if !args.isEmpty {
            let value = args.removeFirst()
            if let mode = VoiceTriggerConfig.Mode(rawValue: value) { VoiceTrigger.config.mode = mode }
            opts.cliTriggerMode = value
        }
    case "--ime":
        if !args.isEmpty {
            let value = args.removeFirst()
            let prefix = value == "none" ? nil : value
            VoiceTrigger.config.imeBundlePrefix = prefix
            opts.cliIMEGiven = true
            opts.cliIME = prefix
        }
    case "--run-action":
        guard !args.isEmpty else {
            FileHandle.standardError.write("--run-action 需要一个 JSON 参数\n".data(using: .utf8)!)
            exit(2)
        }
        do {
            let action = try JSONDecoder().decode(Action.self, from: Data(args.removeFirst().utf8))
            FileHandle.standardError.write("执行动作: \(action)\n".data(using: .utf8)!)
            ActionRunner().run(action)
        } catch {
            FileHandle.standardError.write("动作 JSON 解析失败: \(error)\n".data(using: .utf8)!)
            exit(2)
        }
        // 等动作真正执行完再退出：宏在后台队列串行跑（可能远超 1s），shell 有
        // 10s+2s 的超时清理定时器——主进程提前退出会把二者截断/孤儿化。
        // 轮询「宏不在跑 && 无活动 shell 进程组」，最短 1s，硬上限 120s（超时
        // 时对残余 shell 组 TERM→KILL 清扫后退出）。
        let runActionDeadline = Date().addingTimeInterval(120)
        func pollRunActionExit() {
            let done = !MacroEngine.shared.isRunning && ShellProcessRegistry.shared.activeCount == 0
            if done || Date() > runActionDeadline {
                ShellProcessRegistry.shared.terminateAll()
                exit(done ? 0 : 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pollRunActionExit() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollRunActionExit() }
        RunLoop.main.run()
    case "--help", "-h":
        print("miremote                     GUI 模式（设置窗口 + 引擎）")
        print("miremote --ui-preview        GUI 但不启动引擎（开发验证）")
        print("miremote [--list-audio-devices] [--output <name>] [--wav <path>] [--gain <dB>] [--verbose]")
        print("         [--keys] [--config <path>] [--doubao] [--run-action '<action json>']")
        print("         [--doctor] [--login-item on|off|status] [--claude-hooks install|uninstall|status]")
        exit(0)
    default:
        FileHandle.standardError.write("未知参数: \(argument)\n".data(using: .utf8)!)
        exit(2)
    }
}

// 单独传 --verbose 时沿用旧版 CLI 服务模式。
if opts.verbose && !uiPreview { cliServiceMode = true }

/// 向已运行实例的事件 socket 发一行 JSON（发送 1s 超时，任何失败静默——
/// 这是尽力而为的唤起信号，不能阻塞或干扰第二实例的正常退出）。
func notifyRunningInstance(_ line: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = EventListener.socketPath()
    let fits = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
        let bytes = Array(path.utf8)
        guard bytes.count < buf.count else { return false }
        buf.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
        return true
    }
    guard fits else { return }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    } == 0
    guard connected else { return }
    let payload = Array((line + "\n").utf8)
    _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

// 两份长驻进程会同时争用 hidutil / CGEventTap，CLI 服务模式与 GUI 都要独占；
// --ui-preview（引擎不启动、不装映射不抢键盘，纯界面开发验证）豁免。
if !uiPreview {
    switch HealthMonitor.acquireSingleInstanceLock(mode: cliServiceMode ? "cli" : "gui") {
    case .acquired:
        break
    case .held(let owner):
        if owner?.mode == "cli" {
            // CLI 服务实例明确丢弃 show_ui 事件——发了也弹不出窗口，给真实提示。
            let pid = owner!.pid
            print("MiRemote 正以命令行模式运行（PID \(pid)），请先停止它（Ctrl+C 或 kill \(pid)）再启动本实例。")
        } else {
            // 双击 .app 再次打开＝想看设置窗口：通知 GUI 主实例弹出 UI
            //（菜单栏优先形态的兜底入口）。owner 未知（旧版锁文件）也尽力而为。
            if !cliServiceMode { notifyRunningInstance(#"{"event":"show_ui"}"#) }
            print("已有实例在运行（锁文件 \(HealthMonitor.lockFilePath())）"
                  + (cliServiceMode ? "，本次启动退出。" : "，已请求主实例打开设置窗口。"))
        }
        print("提示：--help / --doctor 等只读命令不受单实例限制，可随时执行。")
        exit(1)
    case .openFailed(let err):
        FileHandle.standardError.write(
            ("单实例锁文件无法创建/打开（\(String(cString: strerror(err)))）：\(HealthMonitor.lockFilePath())\n"
             + "这不是「已有实例在运行」——请检查该目录的权限/磁盘状态后重试。\n").data(using: .utf8)!)
        exit(1)
    }
}

if cliServiceMode && !uiPreview {
    let services = AppServices(options: opts)
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        log("退出中…")
        services.stop()
        exit(0)
    }
    sigint.resume()
    services.start()
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { GUIAppDelegate(uiPreview: uiPreview) }
    app.delegate = delegate
    // 激活策略由 GUIAppDelegate 管理（菜单栏优先形态常驻 .accessory）。
    app.run()
}
