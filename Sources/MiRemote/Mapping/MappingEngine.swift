import Foundation
import os

/// TapEngine 回调线程同步读取的原子分流快照（M3 方向键三态分流）。
/// 写方在引擎串行 queue 内整体替换，读方（CGEventTap runloop 线程）无阻塞读；
/// 允许毫秒级陈旧（见 MappingEngine.publishTapRoute 的竞争窗口注释），但保证不撕裂。
struct TapRoute: Sendable {
    /// 生效层（0=基础层）。非 0 时方向键必须走引擎（层覆盖可能改语义）。
    var effectiveLayer: Int = 0
    /// ok 键是否物理按住（手势前置条件，按住期间方向键走引擎）。
    /// 注意：TapEngine 分流时用自身在 tap 回调里同步锁存的 OK 物理态覆盖此字段
    /// （本字段经引擎 queue 异步更新、可能滞后毫秒级），此处仅作兜底/调试参考。
    var okDown: Bool = false
    /// 「纯原生 tap」的方向键集合：tap=对应原生方向键 keyStroke 且无 hold/double。
    /// layers 允许存在——层激活与否由 effectiveLayer 单独把关。
    var nativeDirections: Set<RemoteKey> = []
}

/// 按键映射状态机（DESIGN.md §3.1-§3.3）。
///
/// 职责：把 `HIDEngine` 产出的原始 `ButtonEvent` 流，按每个物理键的触发模型
/// （tap / hold / double / gesture / layer）解析成 `Action`，交给 `ActionRunning` 执行。
/// 不碰硬件、不碰 UI，纯逻辑 + 定时器。
///
/// 触发模型（逐键、互相独立的小状态机）：
/// - tap：按下后在 holdMs 内松开 = 短按。若该键配了 `double` 且 `doubleMs>0`，松开后进入
///   `waitingDouble`，等满 doubleMs 窗口确认没有第二次按下才发 tap；否则（无 double 或
///   doubleMs==0）松开即零延迟发 tap。
/// - hold：按住超过 holdMs 未松开 = 长按（串行 queue 上 asyncAfter 定时）。触发后打
///   `holdFired` 标记，松开时不再补发 tap。
/// - double：`doubleMs>0` 时，`waitingDouble` 期间的第二次按下即判定双击，立即发 `double`
///   动作并吞掉这次按下的 tap/hold。
/// - gesture（仅 ok 键）：ok 物理按住且其 hold 尚未触发时，若有方向键按下，发
///   `ok.gesture[方向]`，并同时抑制本次 ok 的 tap/hold 和该方向键自身的动作。
/// - layer：hold 动作为 `.layerMomentary(n)` 时，按住期间生效层 n，松开回落；`.layerToggle(n)`
///   点击锁定/解锁。生效层变化调 `delegate.layerChanged`。层激活时，其他键的短按优先查
///   `binding.layers["\(层)"]`，缺失再退回 `tap`。
///
/// 绑定解析：per-app overlay 只覆盖声明的键，其余继承 global（`activeOverlay[key] ?? global[key]`）。
///
/// 线程模型：对外方法（`setConfig`/`setActiveProfile`/`handle`）都把工作投递到同一条串行
/// queue，所有可变状态与定时器回调都只在该 queue 上读写。定时器不用 DispatchWorkItem 取消，
/// 而是每个键持一个自增 `seq` 令牌，回调进来先校验令牌是否仍是最新——按下/松开/被抢占都会
/// 递增令牌，从而作废在途的旧定时器（等价于取消，且对重入更稳）。
///
/// 并发标注：隔离由串行 queue 而非编译器保证，故 `@unchecked Sendable`（同 `ATVVBridge`）。
final class MappingEngine: @unchecked Sendable {

    // MARK: - 逐键状态

    private enum Phase {
        case idle           // 空闲
        case down           // 物理按下中，hold 定时器在途
        case waitingDouble  // 已松开一次，等 doubleMs 窗口确认是否双击
        case consumed       // 本次按压已决断（双击/被手势吞），等物理松开，松开时不产出
    }

    private struct KeyState {
        var phase: Phase = .idle
        var seq: Int = 0            // 定时器令牌：任何状态迁移都自增以作废在途回调
        var holdFired = false       // 本次按压的 hold 是否已触发
        var suppressTap = false     // 手势吞掉了本键（ok）的 tap，松开时不产出
    }

    // MARK: - 依赖与配置

    private let runner: ActionRunning
    private weak var delegate: MappingEngineDelegate?

    private var config: MappingConfig
    private var globalProfile: [String: KeyBinding]
    private var activeOverlay: [String: KeyBinding]?   // 当前前台 app 的覆盖层（nil=纯 global）
    private var activeBundleID: String?

    // MARK: - 运行时状态

    private var states: [RemoteKey: KeyState] = [:]

    /// 锁定层（layerToggle 设置，0=基础层）。
    private var lockedLayer = 0
    /// 瞬时层（layerMomentary 设置，按住期间覆盖 lockedLayer）。
    private var momentaryLayer: Int?
    /// 瞬时层的持有键，松开时清除。
    private var momentaryOwner: RemoteKey?
    /// 上次通知过的生效层，去重 layerChanged。
    private var lastNotifiedLayer = 0

    /// 生效层 = 瞬时层优先，否则锁定层。
    private var effectiveLayer: Int { momentaryLayer ?? lockedLayer }

    /// ok 键物理按住标记（快照用，独立于 states 的相位机）。
    private var okPhysicallyDown = false

    // MARK: - 分流快照（tap 回调线程读，引擎 queue 写）

    /// okDown 竞争窗口（已消除）：ok 按下与方向键几乎同时到达时，本快照的 okDown
    /// 可能尚未更新（tap 回调 → 引擎 queue 异步投递的毫秒级延迟）。TapEngine 已在
    /// tap 回调里同步锁存 OK 物理态并在方向分流判定时覆盖快照的 okDown（OK 也是
    /// 中转键，tap 回调能同步看到它），手势漏判窗口不复存在；快照 okDown 仅作兜底。
    /// 层/纯原生的分流判定仍读本快照（毫秒级陈旧可接受）。不在 tap 回调里
    /// 同步 dispatch 到引擎 queue（有死锁/输入延迟风险）。
    private let tapRouteLock = OSAllocatedUnfairLock(initialState: TapRoute())

    /// 供 TapEngine 在回调线程同步读取的分流快照。
    var tapRoute: TapRoute { tapRouteLock.withLock { $0 } }

    /// 在引擎 queue 内重算并整体替换快照。调用时机：init、setConfig、setActiveProfile、
    /// 生效层变化、ok 物理按下/松开。
    private func publishTapRoute() {
        var native: Set<RemoteKey> = []
        for key in [RemoteKey.up, .down, .left, .right] {
            if let b = binding(for: key),
               b.hold == nil, b.double == nil,
               b.tap == .keyStroke(key: Self.nativeArrowName[key]!, mods: []) {
                native.insert(key)
            }
        }
        let route = TapRoute(effectiveLayer: effectiveLayer,
                             okDown: okPhysicallyDown,
                             nativeDirections: native)
        tapRouteLock.withLock { $0 = route }
    }

    private static let nativeArrowName: [RemoteKey: String] = [
        .up: "up_arrow", .down: "down_arrow", .left: "left_arrow", .right: "right_arrow",
    ]

    // MARK: - 定时/调度注入（便于 selfCheck 用虚拟时钟做确定性测试）

    /// 把工作投递到执行上下文（生产=串行 queue.async；测试=同步就地执行）。
    private let dispatch: (@escaping () -> Void) -> Void
    /// 延迟 ms 毫秒后在执行上下文回调（生产=queue.asyncAfter；测试=虚拟时钟登记）。
    private let scheduleAfter: (Int, @escaping () -> Void) -> Void

    // MARK: - 初始化

    /// 契约要求的入口初始化：内部自建串行 queue，定时器同落该 queue。
    convenience init(config: MappingConfig, runner: ActionRunning, delegate: MappingEngineDelegate?) {
        let queue = DispatchQueue(label: "com.miremote.mapping", qos: .userInitiated)
        self.init(config: config,
                  runner: runner,
                  delegate: delegate,
                  dispatch: { work in queue.async(execute: work) },
                  scheduleAfter: { ms, work in
                      queue.asyncAfter(deadline: .now() + .milliseconds(max(0, ms)), execute: work)
                  })
    }

    /// 指定初始化：注入调度闭包，供 selfCheck 用同步/虚拟时钟驱动。
    private init(config: MappingConfig,
                 runner: ActionRunning,
                 delegate: MappingEngineDelegate?,
                 dispatch: @escaping (@escaping () -> Void) -> Void,
                 scheduleAfter: @escaping (Int, @escaping () -> Void) -> Void) {
        self.config = config
        self.runner = runner
        self.delegate = delegate
        self.dispatch = dispatch
        self.scheduleAfter = scheduleAfter
        self.globalProfile = config.profiles["global"] ?? [:]
        publishTapRoute()
    }

    // MARK: - 对外 API（均切到执行上下文）

    /// 热加载配置。重算 global 与当前 overlay，进行中的按压状态不清（阈值下次按压生效）。
    func setConfig(_ config: MappingConfig) {
        dispatch { [weak self] in self?._setConfig(config) }
    }

    /// 前台 app 变化时调用。解析该 bundle 的 overlay，找不到则纯用 global。
    func setActiveProfile(_ bundleID: String?) {
        dispatch { [weak self] in self?._setActiveProfile(bundleID) }
    }

    /// 喂入原始按键事件。核心入口。
    func handle(_ event: ButtonEvent) {
        dispatch { [weak self] in self?._handle(event) }
    }

    /// 复位全部输入运行态：作废在途定时器、清按键相位/瞬时层/OK 物理态，重发布快照。
    /// 设备移除、系统睡眠、tap 失效恢复等可能丢 keyUp 的场景调用，防止卡键/卡层。
    func resetInputState(reason: String) {
        dispatch { [weak self] in self?._resetInputState(reason) }
    }

    // MARK: - 对外 API 实现（均在执行上下文内）

    private func _setConfig(_ config: MappingConfig) {
        self.config = config
        self.globalProfile = config.profiles["global"] ?? [:]
        // overlay 随新配置重解析（同一 bundle 的绑定可能已改）。
        if let b = activeBundleID, let p = config.profiles[b] {
            activeOverlay = p
        } else {
            activeOverlay = nil
        }
        publishTapRoute()
        log("CONFIG reloaded holdMs=\(config.settings.holdMs) doubleMs=\(config.settings.doubleMs)")
    }

    private func _setActiveProfile(_ bundleID: String?) {
        activeBundleID = bundleID
        if let b = bundleID, let p = config.profiles[b] {
            activeOverlay = p
            log("PROFILE overlay=\(b)")
        } else {
            activeOverlay = nil
            log("PROFILE global (bundle=\(bundleID ?? "nil"))")
        }
        publishTapRoute()
    }

    private func _resetInputState(_ reason: String) {
        // 保留 states 条目、只 bump seq：直接清空会让新按压的 seq 从 0 重计，
        // 可能与在途旧定时器的令牌撞值而误触发。
        for (key, var st) in states {
            st.seq &+= 1
            st.phase = .idle
            st.holdFired = false
            st.suppressTap = false
            states[key] = st
        }
        okPhysicallyDown = false
        momentaryLayer = nil
        momentaryOwner = nil
        recomputeLayer()      // 若在瞬时层则通知回落（内部含快照发布）
        publishTapRoute()     // 层未变化时 recomputeLayer 不发布，这里兜底刷新 okDown
        log("RESET input state (\(reason))")
    }

    private func _handle(_ event: ButtonEvent) {
        if event.key == .ok, okPhysicallyDown != event.isDown {
            okPhysicallyDown = event.isDown
            publishTapRoute()
        }
        if event.isDown {
            handleDown(event.key)
        } else {
            handleUp(event.key)
        }
    }

    // MARK: - 按下

    private func handleDown(_ key: RemoteKey) {
        var st = states[key] ?? KeyState()

        // 1) 手势：ok 物理按住且其 hold 尚未触发时，方向键按下 → 触发 ok.gesture[方向]，
        //    抑制 ok 的 tap/hold 与该方向键自身动作。ok.hold 已触发（如已进瞬时层）则不再算手势，
        //    方向键按常规走层——两者由 holdFired 干净分流。
        if isDirection(key), let dir = gestureDirection(key) {
            let okState = states[.ok] ?? KeyState()
            if okState.phase == .down, !okState.holdFired,
               let gestureAction = binding(for: .ok)?.gesture?[dir] {
                // 抑制 ok：作废其 hold 定时器 + 标记松开不产出 tap。
                var ok = okState
                ok.seq &+= 1
                ok.suppressTap = true
                states[.ok] = ok
                // 抑制方向键自身：进 consumed，松开时不产出。
                st.phase = .consumed
                st.seq &+= 1
                states[key] = st
                perform(gestureAction, key: .ok, isHold: false)
                log("GESTURE ok+\(dir)")
                return
            }
        }

        // 2) 双击窗口内的第二次按下 → 判定双击。
        if st.phase == .waitingDouble {
            st.seq &+= 1                 // 作废在途的 double→tap 定时器
            st.phase = .consumed         // 吞掉这次按压的松开
            states[key] = st
            perform(binding(for: key)?.double, key: key, isHold: false)
            log("DOUBLE \(key)")
            return
        }

        // 3) 常规按下：进 down，起 hold 定时器。
        st.phase = .down
        st.holdFired = false
        st.suppressTap = false
        st.seq &+= 1
        let token = st.seq
        states[key] = st

        scheduleAfter(config.settings.holdMs) { [weak self] in
            self?.onHoldTimer(key, token)
        }
    }

    private func onHoldTimer(_ key: RemoteKey, _ token: Int) {
        guard var st = states[key], st.seq == token, st.phase == .down, !st.holdFired else { return }
        st.holdFired = true
        states[key] = st
        perform(binding(for: key)?.hold, key: key, isHold: true)
        log("HOLD \(key)")
    }

    // MARK: - 松开

    private func handleUp(_ key: RemoteKey) {
        guard var st = states[key] else { return }

        switch st.phase {
        case .idle:
            return

        case .waitingDouble:
            // 双击窗口里不应出现同键松开（应在按下时已消费）；忽略，保持等待。
            return

        case .consumed:
            // 双击第二次按压 / 被手势吞：松开只复位。
            st.seq &+= 1
            st.phase = .idle
            states[key] = st

        case .down:
            st.seq &+= 1   // 作废在途 hold 定时器

            if st.holdFired {
                // hold 已触发：松开时若持有瞬时层则回落。
                if momentaryOwner == key { clearMomentary() }
                st.phase = .idle
                states[key] = st
            } else if st.suppressTap {
                // 手势已吞掉本键（ok）的 tap。
                if momentaryOwner == key { clearMomentary() }
                st.phase = .idle
                states[key] = st
            } else {
                // 短按候选。配了 double 且 doubleMs>0 → 进等待窗口；否则零延迟发 tap。
                let hasDouble = binding(for: key)?.double != nil
                if hasDouble, config.settings.doubleMs > 0 {
                    st.phase = .waitingDouble
                    let token = st.seq
                    states[key] = st
                    scheduleAfter(config.settings.doubleMs) { [weak self] in
                        self?.onDoubleTimer(key, token)
                    }
                } else {
                    st.phase = .idle
                    states[key] = st
                    fireTap(key)
                    log("TAP \(key)")
                }
            }
        }
    }

    private func onDoubleTimer(_ key: RemoteKey, _ token: Int) {
        guard var st = states[key], st.seq == token, st.phase == .waitingDouble else { return }
        st.phase = .idle
        states[key] = st
        fireTap(key)
        log("TAP(after double window) \(key)")
    }

    // MARK: - 动作分发

    /// 短按分发：层激活时优先 `layers["\(层)"]`，缺失退回 `tap`。
    private func fireTap(_ key: RemoteKey) {
        let b = binding(for: key)
        let layer = effectiveLayer
        let action: Action?
        if layer != 0, let layered = b?.layers?["\(layer)"] {
            action = layered
        } else {
            action = b?.tap
        }
        perform(action, key: key, isHold: false)
    }

    /// 统一动作执行：层动作由引擎内部消化，其余交给 runner。
    private func perform(_ action: Action?, key: RemoteKey, isHold: Bool) {
        guard let action else { return }
        switch action {
        case .layerMomentary(let n):
            if isHold {
                activateMomentary(n, owner: key)
            } else {
                // 瞬时层依赖“按住/松开”语义，短按位无从回落——忽略并记录。
                log("layer_momentary on tap ignored for \(key)")
            }
        case .layerToggle(let n):
            toggleLayer(n)
        default:
            runner.run(action)
        }
    }

    // MARK: - 层管理

    private func toggleLayer(_ n: Int) {
        lockedLayer = (lockedLayer == n) ? 0 : n
        recomputeLayer()
    }

    private func activateMomentary(_ n: Int, owner: RemoteKey) {
        momentaryLayer = n
        momentaryOwner = owner
        recomputeLayer()
    }

    private func clearMomentary() {
        momentaryLayer = nil
        momentaryOwner = nil
        recomputeLayer()
    }

    private func recomputeLayer() {
        let eff = effectiveLayer
        guard eff != lastNotifiedLayer else { return }
        lastNotifiedLayer = eff
        publishTapRoute()
        delegate?.layerChanged(eff)
        log("LAYER \(eff)")
    }

    // MARK: - 绑定解析与工具

    /// per-app overlay 只覆盖声明的键，其余继承 global。
    private func binding(for key: RemoteKey) -> KeyBinding? {
        let name = key.rawValue
        return activeOverlay?[name] ?? globalProfile[name]
    }

    private func isDirection(_ k: RemoteKey) -> Bool {
        k == .up || k == .down || k == .left || k == .right
    }

    /// 方向键 → gesture 字典键名；非方向键返回 nil。
    private func gestureDirection(_ k: RemoteKey) -> String? {
        switch k {
        case .up:    return "up"
        case .down:  return "down"
        case .left:  return "left"
        case .right: return "right"
        default:     return nil
        }
    }

    private func log(_ msg: String) {
        delegate?.mappingLog("MAP \(msg)")
    }
}

// MARK: - 纯逻辑自测

extension MappingEngine {

    /// 记录 runner 收到的动作，供断言。
    private final class RecordingRunner: ActionRunning {
        var actions: [Action] = []
        func run(_ action: Action) { actions.append(action) }
    }

    /// 记录层变化，供断言。
    private final class RecordingDelegate: MappingEngineDelegate {
        var layers: [Int] = []
        func mappingLog(_ message: String) {}
        func layerChanged(_ layer: Int) { layers.append(layer) }
    }

    /// 虚拟时钟：登记延迟回调，`advance` 按时间序触发（允许回调再登记新回调）。
    private final class ManualClock {
        private var now = 0
        private var pending: [(at: Int, work: () -> Void)] = []

        func schedule(_ ms: Int, _ work: @escaping () -> Void) {
            pending.append((now + max(0, ms), work))
        }

        func advance(_ ms: Int) {
            let target = now + ms
            while let idx = pending.enumerated()
                .filter({ $0.element.at <= target })
                .min(by: { $0.element.at < $1.element.at })?.offset {
                let item = pending.remove(at: idx)
                now = item.at
                item.work()
            }
            now = target
        }
    }

    /// 构造带 global profile 的测试配置。holdMs=100，doubleMs=80。
    private static func makeTestConfig() -> MappingConfig {
        var cfg = MappingConfig()
        cfg.settings.holdMs = 100
        cfg.settings.doubleMs = 80
        cfg.profiles["global"] = [
            // 只有 tap、无 double → 松开零延迟发 tap
            "back": KeyBinding(tap: .keyStroke(key: "escape", mods: [])),
            // 有 double，且层1有短按覆盖
            "up": KeyBinding(tap: .keyStroke(key: "up_arrow", mods: []),
                             double: .keyStroke(key: "page_up", mods: []),
                             layers: ["1": .keyStroke(key: "k", mods: ["right_option"])]),
            // hold=瞬时层1，gesture 上/右
            "ok": KeyBinding(tap: .keyStroke(key: "return", mods: []),
                             hold: .layerMomentary(1),
                             gesture: ["up": .system("mission_control"),
                                       "right": .keyStroke(key: "right_arrow", mods: [])]),
            // hold=锁定层2
            "tv": KeyBinding(tap: .system("volume_up"),
                             hold: .layerToggle(2)),
        ]
        return cfg
    }

    /// 纯逻辑自测：用虚拟时钟模拟事件序列，断言产出的 action / layer 序列。
    /// 不依赖真实硬件或真实定时器。全部通过返回 true。
    static func selfCheck() -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ msg: String) {
            if !cond { ok = false; print("[MappingEngine.selfCheck] FAIL: \(msg)") }
        }

        // 每个场景独立构建引擎，避免跨场景串扰。
        func makeEngine() -> (MappingEngine, RecordingRunner, RecordingDelegate, ManualClock) {
            let clock = ManualClock()
            let runner = RecordingRunner()
            let del = RecordingDelegate()
            let engine = MappingEngine(config: makeTestConfig(),
                                       runner: runner,
                                       delegate: del,
                                       dispatch: { $0() },
                                       scheduleAfter: { ms, work in clock.schedule(ms, work) })
            return (engine, runner, del, clock)
        }
        func down(_ e: MappingEngine, _ k: RemoteKey) { e.handle(ButtonEvent(key: k, isDown: true, timeNs: 0)) }
        func up(_ e: MappingEngine, _ k: RemoteKey)   { e.handle(ButtonEvent(key: k, isDown: false, timeNs: 0)) }

        // 场景 A：仅 tap、无 double → 松开即刻发 tap（escape）。
        do {
            let (e, r, _, c) = makeEngine()
            down(e, .back); c.advance(10); up(e, .back)
            expect(r.actions == [.keyStroke(key: "escape", mods: [])], "A simple tap immediate")
        }

        // 场景 B：配了 double，等满窗口无第二次 → 发 tap（up_arrow）。
        do {
            let (e, r, _, c) = makeEngine()
            down(e, .up); c.advance(10); up(e, .up)
            expect(r.actions.isEmpty, "B tap deferred until double window")
            c.advance(80)
            expect(r.actions == [.keyStroke(key: "up_arrow", mods: [])], "B tap fires after window")
        }

        // 场景 C：窗口内第二次按下 → 双击（page_up），不发 tap。
        do {
            let (e, r, _, c) = makeEngine()
            down(e, .up); c.advance(10); up(e, .up)   // 首次 tap → waitingDouble
            c.advance(40)                              // 窗口内
            down(e, .up); c.advance(10); up(e, .up)   // 第二次 → 双击
            c.advance(100)                             // 确认无 tap 补发
            expect(r.actions == [.keyStroke(key: "page_up", mods: [])], "C double only, no tap")
        }

        // 场景 D：ok 长按进瞬时层1 → up 短按走层覆盖(k) → ok 松开回落层0；ok 的 return 不发。
        do {
            let (e, r, d, c) = makeEngine()
            down(e, .ok); c.advance(100)               // hold → 瞬时层1
            expect(d.layers == [1], "D layer 1 on hold")
            down(e, .up); c.advance(10); up(e, .up)   // up 有 double → 等窗口
            c.advance(80)                              // 层1 内发 tap
            up(e, .ok)                                 // 松开 ok → 回落
            expect(r.actions == [.keyStroke(key: "k", mods: ["right_option"])], "D layered tap = k")
            expect(d.layers == [1, 0], "D layer back to 0 on release")
        }

        // 场景 E：ok 按住 + 方向上 → 手势(mission_control)，抑制 ok.tap 与方向键动作。
        do {
            let (e, r, d, c) = makeEngine()
            down(e, .ok); c.advance(20)                // ok 按住，hold 未到
            down(e, .up)                               // 方向上 → 手势
            up(e, .up); up(e, .ok)
            c.advance(200)
            expect(r.actions == [.system("mission_control")], "E gesture only")
            expect(d.layers.isEmpty, "E no layer change")
        }

        // 场景 F：tv 长按锁定层2，再长按解锁回层0；tv 的 tap(volume_up) 从不发。
        do {
            let (e, r, d, c) = makeEngine()
            down(e, .tv); c.advance(100); up(e, .tv)   // toggle → 层2
            down(e, .tv); c.advance(100); up(e, .tv)   // toggle → 层0
            expect(d.layers == [2, 0], "F toggle layer on/off")
            expect(r.actions.isEmpty, "F no tap fired while holding")
        }

        if ok { print("[MappingEngine.selfCheck] all scenarios passed") }
        return ok
    }

    /// M3 分流快照 + TapEngine 判定的纯逻辑自测（同步 dispatch + 虚拟时钟）。
    static func tapRouteSelfCheck() -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ msg: String) {
            if !cond { ok = false; print("[MappingEngine.tapRouteSelfCheck] FAIL: \(msg)") }
        }

        // 配置：up/down/left 纯原生（up 带 layers 仍算纯原生——层由 effectiveLayer 把关）；
        // right 配了 double → 非纯原生；ok hold=瞬时层1；tv hold=锁定层2。
        func makeConfig() -> MappingConfig {
            var cfg = MappingConfig()
            cfg.settings.holdMs = 100
            cfg.settings.doubleMs = 80
            cfg.profiles["global"] = [
                "up":    KeyBinding(tap: .keyStroke(key: "up_arrow", mods: []),
                                    layers: ["1": .system("volume_up")]),
                "down":  KeyBinding(tap: .keyStroke(key: "down_arrow", mods: [])),
                "left":  KeyBinding(tap: .keyStroke(key: "left_arrow", mods: [])),
                "right": KeyBinding(tap: .keyStroke(key: "right_arrow", mods: []),
                                    double: .system("play_pause")),
                "ok":    KeyBinding(tap: .keyStroke(key: "return", mods: []),
                                    hold: .layerMomentary(1),
                                    gesture: ["up": .system("mission_control")]),
                "tv":    KeyBinding(hold: .layerToggle(2)),
            ]
            cfg.profiles["com.example.app"] = [
                "down": KeyBinding(tap: .keyStroke(key: "down_arrow", mods: []),
                                   hold: .system("mute")),   // overlay 里 down 带 hold → 非纯原生
            ]
            return cfg
        }

        let clock = ManualClock()
        let engine = MappingEngine(config: makeConfig(),
                                   runner: RecordingRunner(),
                                   delegate: nil,
                                   dispatch: { $0() },
                                   scheduleAfter: { ms, work in clock.schedule(ms, work) })
        func down(_ k: RemoteKey) { engine.handle(ButtonEvent(key: k, isDown: true, timeNs: 0)) }
        func up(_ k: RemoteKey)   { engine.handle(ButtonEvent(key: k, isDown: false, timeNs: 0)) }

        // 1) 初始快照：层0、ok 未按、up/down/left 纯原生、right 不是（有 double）。
        var r = engine.tapRoute
        expect(r.effectiveLayer == 0 && !r.okDown, "1 initial layer/ok")
        expect(r.nativeDirections == [.up, .down, .left], "1 nativeDirections")

        // 2) 判定：纯原生方向 → 改写放行（含 autorepeat 也由 TapEngine 按压记录跟随）。
        expect(KeyRemapper.directionVerdict(key: .up, isRepeat: false, route: r) == .rewrite(126),
               "2 up → rewrite(126)")
        expect(KeyRemapper.directionVerdict(key: .right, isRepeat: false, route: r) == .engine,
               "2 right(有double) → engine")
        expect(KeyRemapper.directionVerdict(key: .right, isRepeat: true, route: r) == .drop,
               "2 right autorepeat → drop")
        expect(KeyRemapper.directionVerdict(key: .ok, isRepeat: false, route: r) == nil,
               "2 非方向键 → nil")

        // 3) ok 物理按下 → 快照 okDown，方向键走引擎（手势窗口）；松开还原。
        down(.ok)
        r = engine.tapRoute
        expect(r.okDown, "3 okDown after ok down")
        expect(KeyRemapper.directionVerdict(key: .up, isRepeat: false, route: r) == .engine,
               "3 up under ok → engine")
        up(.ok); clock.advance(200)
        expect(!engine.tapRoute.okDown, "3 okDown cleared after ok up")

        // 4) ok 长按进瞬时层1 → 快照层1；松开回落层0。
        down(.ok); clock.advance(100)
        r = engine.tapRoute
        expect(r.effectiveLayer == 1, "4 momentary layer in snapshot")
        expect(KeyRemapper.directionVerdict(key: .up, isRepeat: false, route: r) == .engine,
               "4 layered up → engine")
        up(.ok)
        expect(engine.tapRoute.effectiveLayer == 0, "4 layer back to 0")

        // 5) tv 长按锁定层2 → 快照层2；再长按解锁。
        down(.tv); clock.advance(100); up(.tv)
        expect(engine.tapRoute.effectiveLayer == 2, "5 locked layer in snapshot")
        down(.tv); clock.advance(100); up(.tv)
        expect(engine.tapRoute.effectiveLayer == 0, "5 unlocked")

        // 6) setActiveProfile overlay：down 被 overlay 覆盖成带 hold → 失去纯原生；切回还原。
        engine.setActiveProfile("com.example.app")
        expect(engine.tapRoute.nativeDirections == [.up, .left], "6 overlay drops down")
        engine.setActiveProfile(nil)
        expect(engine.tapRoute.nativeDirections == [.up, .down, .left], "6 restore on global")

        // 7) setConfig 热加载：up 增加 hold → 失去纯原生。
        var cfg2 = makeConfig()
        cfg2.profiles["global"]?["up"]?.hold = .system("mute")
        engine.setConfig(cfg2)
        expect(engine.tapRoute.nativeDirections == [.down, .left], "7 config reload drops up")

        if ok { print("[MappingEngine.tapRouteSelfCheck] all scenarios passed") }
        return ok
    }

    /// resetInputState 加固自测：瞬时层回落、OK 物理态清除、在途定时器作废、孤儿 keyUp 无副作用。
    static func resetSelfCheck() -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ msg: String) {
            if !cond { ok = false; print("[MappingEngine.resetSelfCheck] FAIL: \(msg)") }
        }
        let clock = ManualClock()
        let runner = RecordingRunner()
        let del = RecordingDelegate()
        let engine = MappingEngine(config: makeTestConfig(),
                                   runner: runner,
                                   delegate: del,
                                   dispatch: { $0() },
                                   scheduleAfter: { ms, work in clock.schedule(ms, work) })
        func down(_ k: RemoteKey) { engine.handle(ButtonEvent(key: k, isDown: true, timeNs: 0)) }
        func up(_ k: RemoteKey)   { engine.handle(ButtonEvent(key: k, isDown: false, timeNs: 0)) }

        // 1) ok 长按进瞬时层1 → reset（模拟睡眠）→ 层回落 0、okDown 清除、快照刷新。
        down(.ok); clock.advance(100)
        expect(engine.tapRoute.effectiveLayer == 1 && engine.tapRoute.okDown, "1 hold 后层1+okDown")
        engine.resetInputState(reason: "test-sleep")
        expect(engine.tapRoute.effectiveLayer == 0 && !engine.tapRoute.okDown, "1 reset 后层0+okDown清除")
        expect(del.layers == [1, 0], "1 reset 通知层回落")
        // 丢失的 keyUp 事后到达：无动作产出。
        up(.ok); clock.advance(300)
        expect(runner.actions.isEmpty, "1 reset 后孤儿 keyUp 无产出")

        // 2) 在途 hold 定时器被作废：tv 按下 → reset → 时间推进不触发 layerToggle。
        down(.tv)
        engine.resetInputState(reason: "test-cancel-hold")
        clock.advance(200)
        expect(del.layers == [1, 0], "2 reset 作废在途 hold 定时器")
        up(.tv); clock.advance(200)
        expect(runner.actions.isEmpty && del.layers == [1, 0], "2 作废后 up 亦无产出")

        // 3) reset 后正常按键流程不受影响。
        down(.back); clock.advance(10); up(.back)
        expect(runner.actions == [.keyStroke(key: "escape", mods: [])], "3 reset 后正常 tap")

        if ok { print("[MappingEngine.resetSelfCheck] passed") }
        return ok
    }
}
