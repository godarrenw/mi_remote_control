import AppKit
import CoreGraphics
import os

/// 鼠标模式（DESIGN §4.5）：toggle 进入后由本模块接管方向键/OK/菜单/返回的语义。
///
/// 与 MappingEngine 的集成点（接线不在本文件，留给按键侧）：
///   1. MappingEngine 收到 ButtonEvent 时先调 `MouseMode.shared.handle(key:isDown:)`，
///      返回 true 表示事件已被鼠标模式消费，映射层不再处理；返回 false（音量/电源/语音等）走原映射。
///   2. `Action.mouseMode` 绑到任意键（ActionRunner 分发到 `toggle()`）即可进出模式。
///   3. 模式内语义：方向=光标匀加速移动（多方向同按=对角线）、OK=左键单击、菜单=右键单击、返回=退出模式。
///   4. `isActive` 供状态角标/菜单栏反馈读取。
///
/// 实现：60Hz DispatchSourceTimer（专用串行 queue 驱动 + 保护全部状态）；
/// 按住方向从 4px/tick 起 1.5s 线性加速到 40px/tick；
/// 移动 = CGWarpMouseCursorPosition + 合成 mouseMoved 事件（让 app 感知悬停）。
final class MouseMode: @unchecked Sendable {
    static let shared = MouseMode()

    // MARK: - 加速曲线（纯函数，单测覆盖）

    static let baseSpeed = 4.0    // px/tick 初速
    static let maxSpeed = 40.0    // px/tick 满速
    static let rampSeconds = 1.5  // 线性加速时长
    static let idleSeconds = 20

    /// 按住 t 秒后的速度（px/tick）：4 起步，1.5s 线性到 40，之后恒定。
    static func speed(afterSeconds t: Double) -> Double {
        if t <= 0 { return baseSpeed }
        if t >= rampSeconds { return maxSpeed }
        return baseSpeed + (maxSpeed - baseSpeed) * (t / rampSeconds)
    }

    /// 方向集合 → 位移向量（CG 全局坐标系：y 向下增大）。多方向同按=对角线。
    static func delta(dirs: Set<RemoteKey>, speed: Double) -> (dx: Double, dy: Double) {
        var dx = 0.0, dy = 0.0
        if dirs.contains(.left) { dx -= 1 }
        if dirs.contains(.right) { dx += 1 }
        if dirs.contains(.up) { dy -= 1 }
        if dirs.contains(.down) { dy += 1 }
        return (dx * speed, dy * speed)
    }

    // MARK: - 状态（全部由串行 q 保护）

    private let q = DispatchQueue(label: "com.miremote.mousemode")
    private var active = false
    private var timer: DispatchSourceTimer?
    private var held: Set<RemoteKey> = []
    private var holdStartNs: UInt64 = 0
    private var idleSeq = 0
    private let source = CGEventSource(stateID: .combinedSessionState)

    /// active 的无阻塞只读镜像：TapEngine 在 tap 回调热路径分流方向键时读取，
    /// 不能 q.sync（避免热路径跨队列同步）。写方仅 activate/deactivateLocked。
    private let activeFlag = OSAllocatedUnfairLock(initialState: false)

    var isActive: Bool { activeFlag.withLock { $0 } }

    // MARK: - 对外接口

    /// 进入/退出鼠标模式（Action.mouseMode 由 ActionRunner 调这里）。
    func toggle() {
        q.sync { active ? deactivateLocked() : activateLocked() }
    }

    /// 显式退出（幂等）。逃生键/暂停遥控等兜底路径调用。
    func deactivate() {
        q.sync { if active { deactivateLocked() } }
    }

    /// 按键事件入口（MappingEngine 侧接线调用，任意线程安全）。
    /// 返回 true = 事件已消费；false = 与鼠标模式无关，按原映射处理。
    func handle(key: RemoteKey, isDown: Bool) -> Bool {
        q.sync {
            guard active else { return false }
            let consumed: Bool
            switch key {
            case .up, .down, .left, .right:
                if isDown {
                    if held.isEmpty { holdStartNs = DispatchTime.now().uptimeNanoseconds }
                    held.insert(key)
                } else {
                    held.remove(key)
                    if held.isEmpty { holdStartNs = 0 }
                }
                consumed = true
            case .ok:
                if isDown { click(.left) }
                consumed = true
            case .menu:
                if isDown { click(.right) }
                consumed = true
            case .back:
                if isDown { deactivateLocked() }
                consumed = true
            default:
                consumed = false  // 音量/电源/语音等保持原映射
            }
            if consumed, active { restartIdleTimerLocked() }
            return consumed
        }
    }

    // MARK: - 内部（均已持有 q）

    private func activateLocked() {
        active = true
        activeFlag.withLock { $0 = true }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2)) // ~60Hz
        t.setEventHandler { [weak self] in self?.tick() } // handler 在 q 上执行，可直接碰状态
        t.resume()
        timer = t
        restartIdleTimerLocked()
        NSLog("[MouseMode] 进入鼠标模式")
    }

    private func deactivateLocked() {
        active = false
        idleSeq &+= 1
        activeFlag.withLock { $0 = false }
        timer?.cancel()
        timer = nil
        held.removeAll()
        holdStartNs = 0
        NSLog("[MouseMode] 退出鼠标模式")
    }

    private func restartIdleTimerLocked() {
        idleSeq &+= 1
        let token = idleSeq
        q.asyncAfter(deadline: .now() + .seconds(Self.idleSeconds)) { [weak self] in
            guard let self, self.active, self.idleSeq == token else { return }
            // 持续按住方向键是活动操作，不在移动中途强退。
            if !self.held.isEmpty {
                self.restartIdleTimerLocked()
                return
            }
            self.deactivateLocked()
            NSLog("[MouseMode] 空闲 \(Self.idleSeconds)s 自动退出")
        }
    }

    /// 定时器 tick（在 q 上）：按住时长 → 速度 → 位移 → warp + mouseMoved。
    private func tick() {
        guard active, !held.isEmpty, holdStartNs > 0 else { return }
        let t = Double(DispatchTime.now().uptimeNanoseconds &- holdStartNs) / 1_000_000_000
        let (dx, dy) = Self.delta(dirs: held, speed: Self.speed(afterSeconds: t))
        guard dx != 0 || dy != 0 else { return }
        let cur = CGEvent(source: nil)?.location ?? .zero
        // v1 先 clamp 到主屏（多显示器跨屏留给 v2；warp 越界会被系统忽略导致卡边）
        let bounds = CGDisplayBounds(CGMainDisplayID())
        var p = CGPoint(x: cur.x + dx, y: cur.y + dy)
        p.x = min(max(p.x, bounds.minX), bounds.maxX - 1)
        p.y = min(max(p.y, bounds.minY), bounds.maxY - 1)
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// 在当前光标位置合成一次单击（在 q 上）。
    private func click(_ button: CGMouseButton) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let types: (down: CGEventType, up: CGEventType) =
            button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        guard let down = CGEvent(mouseEventSource: source, mouseType: types.down,
                                 mouseCursorPosition: pos, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: types.up,
                               mouseCursorPosition: pos, mouseButton: button) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
