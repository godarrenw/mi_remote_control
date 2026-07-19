import Foundation
import AppKit

// MiRemote 入口。
// - 纯 CLI 子命令直接执行后退出，不创建 NSApplication。
// - 显式服务参数保持原 CLI 行为。
// - 无参数（或 --ui-preview）进入 SwiftUI App。

// 纯逻辑自检不触碰 BLE/hidutil，允许在 GUI 正在运行时并行执行（打包校验需要）。
let startupArgs = Array(CommandLine.arguments.dropFirst())
if startupArgs == ["--self-test"] { exit(SelfTest.run()) }

// 两份进程会同时争用 hidutil / CGEventTap，因此所有模式都先获取单实例锁。
if !HealthMonitor.acquireSingleInstanceLock() {
    print("已有实例在运行（锁文件 \(HealthMonitor.lockFilePath())），本次启动退出。")
    exit(1)
}

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
        let report = HealthMonitor.runRepair()
        print("MiRemote 一键体检")
        report.lines().forEach { print($0) }
        print(report.needsUser
              ? "—— 存在需要你处理的项，请按上面的指引操作后重跑 --doctor。"
              : "—— 全部检查通过。")
        exit(report.exitCode)
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
    case "--trigger-key":
        if !args.isEmpty { VoiceTrigger.config.keyName = args.removeFirst() }
    case "--trigger-mode":
        if !args.isEmpty, let mode = VoiceTriggerConfig.Mode(rawValue: args.removeFirst()) {
            VoiceTrigger.config.mode = mode
        }
    case "--ime":
        if !args.isEmpty {
            let value = args.removeFirst()
            VoiceTrigger.config.imeBundlePrefix = value == "none" ? nil : value
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        RunLoop.main.run()
    case "--help", "-h":
        print("miremote                     GUI 模式（设置窗口 + 引擎）")
        print("miremote --ui-preview        GUI 但不启动引擎（开发验证）")
        print("miremote [--list-audio-devices] [--output <name>] [--wav <path>] [--gain <dB>] [--verbose]")
        print("         [--keys] [--config <path>] [--doubao] [--run-action '<action json>']")
        print("         [--doctor] [--login-item on|off|status]")
        exit(0)
    default:
        FileHandle.standardError.write("未知参数: \(argument)\n".data(using: .utf8)!)
        exit(2)
    }
}

// 单独传 --verbose 时沿用旧版 CLI 服务模式。
if opts.verbose && !uiPreview { cliServiceMode = true }

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
    app.setActivationPolicy(.regular)
    app.run()
}
