import Foundation
import AppKit
import UserNotifications
import os

// MARK: - Agent 事件模型（等待批准主动提醒子系统）

/// 外部 CLI（Claude Code 等）经 hook 发来的一行 JSON 事件。
/// 协议样例：{"event":"waiting_approval","source":"claude-code","session":"abc","cwd":"/p","message":"..."}
/// 未知字段忽略；未知 event / 解析失败 → 丢弃。
struct AgentEvent: Equatable {
    enum Kind: String {
        case waitingApproval = "waiting_approval"
        case agentDone       = "agent_done"
        case agentNeedsInput = "agent_needs_input"
        /// 第二实例（用户再次打开 .app）请求主实例弹出设置窗口（菜单栏优先形态的兜底入口）。
        case showUI          = "show_ui"
    }
    let kind: Kind
    let source: String
    let session: String
    let cwd: String
    let message: String

    /// 一行 JSON → 事件（纯函数，self-test 直接测）。
    static func parse(line: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = (obj["event"] as? String).flatMap(Kind.init(rawValue:))
        else { return nil }
        return AgentEvent(kind: kind,
                          source: obj["source"] as? String ?? "",
                          session: obj["session"] as? String ?? "",
                          cwd: obj["cwd"] as? String ?? "",
                          message: obj["message"] as? String ?? "")
    }
}

/// 「哪个会话在等批准/输入」——供未来 UI 徽标与会话切换消费。
struct PendingSession: Equatable {
    let session: String
    let cwd: String
    let message: String
    let kind: AgentEvent.Kind
    let since: Date
}

// MARK: - EventListener（Unix domain socket，JSON 行协议）

/// 监听 ~/Library/Application Support/MiRemote/events.sock。
/// 发信端一次连接发一行或多行 JSON 后关闭（nc -U 语义），本端逐行解析回调。
final class EventListener: @unchecked Sendable {

    static func socketPath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemote", isDirectory: true)
            .appendingPathComponent("events.sock").path
    }

    /// 事件回调（接线期设置，之后只读；从后台队列调用）。
    var onEvent: ((AgentEvent) -> Void)?
    var log: ((String) -> Void)?

    private let pending = OSAllocatedUnfairLock(initialState: [PendingSession]())
    private let queue = DispatchQueue(label: "com.miremote.events")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    var pendingApprovals: [PendingSession] { pending.withLock { $0 } }

    /// 事件 → 等待列表维护（纯状态机，self-test 直接测）：
    /// waiting_approval / agent_needs_input 按 session 去重更新；agent_done 移除该 session。
    func track(_ event: AgentEvent) {
        guard event.kind != .showUI else { return }   // UI 唤起信号，不进等待列表
        pending.withLock { list in
            list.removeAll { $0.session == event.session }
            if event.kind != .agentDone {
                list.append(PendingSession(session: event.session, cwd: event.cwd,
                                           message: event.message, kind: event.kind, since: Date()))
            }
        }
    }

    func start() {
        let path = Self.socketPath()
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path) // 单实例锁保证没有并行监听者，残留 socket 直接清

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log?("事件监听启动失败：socket() errno=\(errno)"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < buf.count else { return false }
            buf.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
            return true
        }
        guard ok else { close(fd); log?("事件监听启动失败：socket 路径过长"); return }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd); log?("事件监听启动失败：bind/listen errno=\(errno)"); return
        }
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
        log?("事件监听已启动：\(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath())
    }

    private func acceptConnection() {
        let conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        // 发信端（nc -w 1）发完即关，连接短命；阻塞读到 EOF 后逐行解析。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(conn, &buf, buf.count)
                guard n > 0 else { break }
                data.append(buf, count: n)
                if data.count > 64 * 1024 { break } // 异常长输入直接截断
            }
            close(conn)
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let event = AgentEvent.parse(line: trimmed) else {
                    self?.log?("事件解析失败，丢弃：\(trimmed.prefix(200))")
                    continue
                }
                self?.track(event)
                self?.onEvent?(event)
            }
        }
    }
}

// MARK: - 系统通知/提示音（事件消费默认实现）

enum AgentNotifier {

    static func describe(_ event: AgentEvent) -> (title: String, body: String) {
        let dir = (event.cwd as NSString).lastPathComponent
        let where_ = dir.isEmpty ? "" : "（\(dir)）"
        switch event.kind {
        case .waitingApproval: return ("Claude 在等你批准\(where_)", event.message)
        case .agentNeedsInput: return ("Claude 需要你输入\(where_)", event.message)
        case .agentDone:       return ("任务完成\(where_)", event.message)
        case .showUI:          return ("MiRemote", "打开设置窗口")
        }
    }

    /// 未打包 CLI 下 UNUserNotificationCenter 会因无 bundle 身份抛
    /// NSInternalInconsistencyException（Swift 不可捕获），因此严格按打包态分流：
    /// .app → 系统通知 + 提示音；裸二进制 → NSSound 提示音 + 日志。
    static func notify(_ event: AgentEvent, log: ((String) -> Void)? = nil) {
        guard event.kind != .showUI else { return }   // 由 GUI 层消费，不发通知
        let (title, body) = describe(event)
        log?("Agent 事件：\(title)\(body.isEmpty ? "" : " — \(body)")")
        playSound(for: event.kind)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: "miremote-\(event.session)-\(event.kind.rawValue)",
                                            content: content, trigger: nil)
            center.add(req)
        }
    }

    private static func playSound(for kind: AgentEvent.Kind) {
        let name = kind == .agentDone ? "Glass" : "Ping"
        DispatchQueue.main.async { NSSound(named: name)?.play() }
    }
}
