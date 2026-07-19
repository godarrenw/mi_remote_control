import Foundation

// MARK: - Claude Code hooks 安装器
//
// 往 ~/.claude/settings.json 注入三条 hook（保留用户已有 hooks，幂等，卸载只删自己的）：
//   hooks.Notification  matcher "permission_prompt"   → miremote-notify.sh waiting_approval
//   hooks.Notification  matcher "agent_needs_input"   → miremote-notify.sh agent_needs_input
//   hooks.Stop          （无 matcher）                → miremote-notify.sh agent_done
// 自己的条目以 command 中的 "miremote-notify.sh" 标记识别。
// 修改前备份 settings.json.miremote-bak；发信脚本安装到 App Support/MiRemote/。

enum ClaudeHooks {

    static let marker = "miremote-notify.sh"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
    }

    static var scriptURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemote", isDirectory: true)
            .appendingPathComponent("miremote-notify.sh")
    }

    /// 发信端脚本（与仓库 scripts/miremote-notify.sh 同源；改动需同步）。
    /// MiRemote 未运行时静默退出，nc 超时 1s，绝不阻塞 Claude Code。
    static let scriptBody = """
    #!/bin/bash
    # MiRemote hook 发信端：把 Claude Code hook 事件转成一行 JSON 发到本地 socket。
    # 用法：miremote-notify.sh <waiting_approval|agent_done|agent_needs_input>（hook stdin 喂 JSON）
    EVENT="${1:-waiting_approval}"
    SOCK="$HOME/Library/Application Support/MiRemote/events.sock"
    [ -S "$SOCK" ] || exit 0
    PAYLOAD=$(/usr/bin/python3 -c '
    import json, sys
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    print(json.dumps({"event": sys.argv[1], "source": "claude-code",
                      "session": d.get("session_id", ""), "cwd": d.get("cwd", ""),
                      "message": d.get("message", "")}))' "$EVENT" 2>/dev/null) || exit 0
    printf '%s\\n' "$PAYLOAD" | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
    exit 0
    """

    // MARK: 纯合并逻辑（self-test 直接测）

    private static let entryList: [(event: String, matcher: String?, arg: String)] =
        [("Notification", "permission_prompt", "waiting_approval"),
         ("Notification", "agent_needs_input", "agent_needs_input"),
         ("Stop", nil, "agent_done")]

    private static func command(scriptPath: String, arg: String) -> String {
        "/bin/bash \"\(scriptPath)\" \(arg)"
    }

    static func isInstalled(_ root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return entryList.allSatisfy { entry in
            (hooks[entry.event] as? [[String: Any]] ?? []).contains { group in
                (entry.matcher == nil || group["matcher"] as? String == entry.matcher)
                    && (group["hooks"] as? [[String: Any]] ?? []).contains {
                        ($0["command"] as? String)?.contains(marker) == true
                    }
            }
        }
    }

    /// 注入（幂等：同 event+matcher 下已有含标记的条目则跳过）。
    static func inject(into root: [String: Any], scriptPath: String) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for entry in entryList {
            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            let already = groups.contains { group in
                (entry.matcher == nil || group["matcher"] as? String == entry.matcher)
                    && (group["hooks"] as? [[String: Any]] ?? []).contains {
                        ($0["command"] as? String)?.contains(marker) == true
                    }
            }
            guard !already else { continue }
            var group: [String: Any] = ["hooks": [["type": "command",
                                                   "command": command(scriptPath: scriptPath, arg: entry.arg),
                                                   "timeout": 5]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[entry.event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    /// 卸载：只删 command 含标记的 hook；清掉因此变空的组/事件；hooks 本身变空则移除。
    static func remove(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var group = group
                let kept = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains(marker) != true
                }
                guard !kept.isEmpty else { return nil }
                group["hooks"] = kept
                return group
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    // MARK: 文件操作（settingsURL/scriptURL 可注入，测试用临时目录实测）

    private static func load(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func save(_ root: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func installed(settings: URL = settingsURL) -> Bool {
        load(settings).map(isInstalled) ?? false
    }

    static func install(settings: URL = settingsURL, script: URL = scriptURL) -> (message: String, code: Int32) {
        guard let root = load(settings) else {
            return ("安装失败：\(settings.path) 不是合法 JSON，请手动检查后重试。", 1)
        }
        do {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try scriptBody.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return ("安装失败：发信脚本写入失败（\(error.localizedDescription)）", 1)
        }
        if isInstalled(root) {
            return ("Claude Code hooks 已安装过，无需重复操作。", 0)
        }
        if FileManager.default.fileExists(atPath: settings.path) {
            let bak = settings.appendingPathExtension("miremote-bak")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: settings, to: bak)
        }
        try? FileManager.default.createDirectory(at: settings.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard save(inject(into: root, scriptPath: script.path), to: settings) else {
            return ("安装失败：\(settings.path) 写入失败。", 1)
        }
        return ("已安装：Claude Code 等待批准/需要输入/任务完成时将通知 MiRemote（备份 settings.json.miremote-bak）。", 0)
    }

    static func uninstall(settings: URL = settingsURL, script: URL = scriptURL) -> (message: String, code: Int32) {
        guard let root = load(settings) else {
            return ("卸载失败：\(settings.path) 不是合法 JSON，请手动检查。", 1)
        }
        guard isInstalled(root) else {
            try? FileManager.default.removeItem(at: script)
            return ("Claude Code hooks 未安装，无需卸载。", 0)
        }
        guard save(remove(from: root), to: settings) else {
            return ("卸载失败：\(settings.path) 写入失败。", 1)
        }
        try? FileManager.default.removeItem(at: script)
        return ("已卸载 MiRemote 的 Claude Code hooks（其它 hooks 未动）。", 0)
    }

    static func status(settings: URL = settingsURL) -> String {
        installed(settings: settings)
            ? "Claude Code hooks：已安装（\(settings.path)）"
            : "Claude Code hooks：未安装。运行 miremote --claude-hooks install 开启等待批准提醒。"
    }
}
