import Foundation

/// 需要让新授予的 TCC 权限进入真实输入通道时，可靠地退出当前进程并重新拉起 App。
@MainActor
enum AppLifecycle {
    static func quitAndRelaunch(_ model: AppModel) {
        model.services?.stop()
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            exit(EXIT_SUCCESS)
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n \"$2\"",
            "miremote-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        do {
            try helper.run()
        } catch {
            log("自动重开失败，请手动重新打开 App：\(error.localizedDescription)")
        }
        exit(EXIT_SUCCESS)
    }

    static func quit(_ model: AppModel) {
        model.services?.stop()
        exit(EXIT_SUCCESS)
    }
}
