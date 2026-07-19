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
///
/// 资源纪律（Codex 终审加固）：
/// - 生命周期（start/stop）与全部连接状态串行在同一 queue 上，无锁读写窗口；
/// - 监听/连接 fd 一律 CLOEXEC + 非阻塞，连接用 DispatchSourceRead（不占独立线程）；
/// - 连接有空闲超时与并发上限，stop 关闭全部在途连接；fd 只在各自 source 的
///   cancel handler 里关闭（取消是异步的，提前 close 会砸到已复用的 fd）。
final class EventListener: @unchecked Sendable {

    static func socketPath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemote", isDirectory: true)
            .appendingPathComponent("events.sock").path
    }

    /// 空闲超时：连接建立后迟迟不发数据/不关闭（如恶意/挂死客户端）即强制收尾。
    static let idleTimeout: TimeInterval = 10
    /// 并发连接上限：超过直接拒绝（发信端是一次一行的 nc 语义，正常永远到不了）。
    static let maxConnections = 16
    /// 单连接最大字节数：超出即截断处理。
    static let maxBytes = 64 * 1024

    /// 事件回调（接线期设置，之后只读；从后台队列调用）。
    var onEvent: ((AgentEvent) -> Void)?
    var log: ((String) -> Void)?

    /// 监听 socket 路径（默认生产路径；测试可注入临时路径）。
    private let path: String

    init(path: String = EventListener.socketPath()) {
        self.path = path
    }

    private let pending = OSAllocatedUnfairLock(initialState: [PendingSession]())
    /// 生命周期与连接状态的唯一执行上下文。
    private let queue = DispatchQueue(label: "com.miremote.events")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// 在途连接（仅 queue 上读写）。
    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        let idleTimer: DispatchSourceTimer
        var data = Data()
        init(fd: Int32, source: DispatchSourceRead, idleTimer: DispatchSourceTimer) {
            self.fd = fd
            self.source = source
            self.idleTimer = idleTimer
        }
    }
    private var connections: [Int32: Connection] = [:]

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

    private static func setCloexecNonblock(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    func start() {
        queue.sync { startLocked() }
    }

    private func startLocked() {
        guard listenFD < 0 else { return }   // 幂等：已在监听
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path) // 单实例锁保证没有并行监听者，残留 socket 直接清

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log?("事件监听启动失败：socket() errno=\(errno)"); return }
        Self.setCloexecNonblock(fd)
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
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }   // fd 只在取消完成后关闭
        source.resume()
        acceptSource = source
        log?("事件监听已启动：\(path)")
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        guard listenFD >= 0 else { return }
        acceptSource?.cancel()   // cancel handler 负责 close(listenFD)
        acceptSource = nil
        listenFD = -1
        for conn in connections.values { teardown(conn, parse: false) }
        connections.removeAll()
        unlink(path)
    }

    /// accept 循环（listen fd 非阻塞：一次事件把积压的连接全收完）。
    private func acceptPending() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }   // EAGAIN/EWOULDBLOCK：本轮收完
            Self.setCloexecNonblock(fd)
            guard connections.count < Self.maxConnections else {
                close(fd)
                log?("事件连接数超上限 \(Self.maxConnections)，拒绝新连接")
                continue
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let conn = Connection(fd: fd, source: source, idleTimer: timer)
            connections[fd] = conn
            source.setEventHandler { [weak self] in self?.readAvailable(conn) }
            source.setCancelHandler { close(fd) }   // 连接 fd 同样只在取消后关闭
            timer.schedule(deadline: .now() + Self.idleTimeout)
            timer.setEventHandler { [weak self] in
                self?.log?("事件连接空闲超时，强制收尾（fd=\(fd)）")
                self?.finish(conn)
            }
            source.resume()
            timer.resume()
        }
    }

    /// 非阻塞读尽当前可读数据；EOF 或超长即收尾解析。
    private func readAvailable(_ conn: Connection) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn.fd, &buf, buf.count)
            if n > 0 {
                conn.data.append(buf, count: n)
                if conn.data.count > Self.maxBytes { finish(conn); return } // 异常长输入直接截断
                continue
            }
            if n == 0 { finish(conn); return }              // EOF：发信端发完即关
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            finish(conn); return                            // 其他读错误：按收到的内容收尾
        }
    }

    /// 正常收尾：解析已收数据并释放连接资源。
    private func finish(_ conn: Connection) {
        teardown(conn, parse: true)
        connections.removeValue(forKey: conn.fd)
    }

    private func teardown(_ conn: Connection, parse: Bool) {
        conn.idleTimer.cancel()
        conn.source.cancel()   // cancel handler 关闭 fd
        guard parse, let text = String(data: conn.data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let event = AgentEvent.parse(line: trimmed) else {
                log?("事件解析失败，丢弃：\(trimmed.prefix(200))")
                continue
            }
            track(event)
            onEvent?(event)
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
