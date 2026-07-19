import Foundation
import CoreGraphics
import os

/// M2 按键接管的最终架构（实机验证 2026-07-19）：
/// macOS 不允许用户态 seize 蓝牙 HID 键盘（0xE00002C1），IOHID 独占不可行。
/// 正路：hidutil 把有副作用的键在内核层重映射到 F13-F19（系统零默认行为），
/// 再用 CGEventTap 捕获并吞掉这些中转键，反查回原始键触发动作。
/// 音量键保持系统原生（默认行为即所需）。
/// M3：方向键也进中转表，TapEngine 按 MappingEngine 快照三态分流：
/// 纯原生场景就地改写回方向键 keycode 放行（保住系统 autorepeat 与零延迟），
/// 层/手势场景吞掉喂引擎。
///
/// 已知限制（v1 接受）：Secure Input（密码框等安全输入）期间 CGEventTap 被系统
/// 旁路，而 hidutil 映射仍然生效——遥控器方向键会以中转键（F13/F19/F20/小键盘
/// Clear）泄漏进前台应用，破坏原生光标导航。只有遥控器受影响，真键盘不经过
/// hidutil 重映射、不受影响。未来可轮询 IsSecureEventInputEnabled()，进入
/// Secure Input 时临时卸载方向键映射、退出后重装。

enum KeyRemapper {

    /// 日志通道（main 接线；nil 时静默）。
    nonisolated(unsafe) static var log: ((String) -> Void)?

    /// (遥控器原始 usage, 中转键 usage, 中转键 macOS keycode, 逻辑键)
    static let table: [(src: UInt32, dst: UInt32, keycode: Int64, key: RemoteKey)] = [
        // back(0xF1) 不在此表：超出标准键盘 usage 范围，hidutil 不认、系统也忽略它，
        // 它由 IOHID 监听通道直接读取（无双触发风险，系统本来就不处理 0xF1）。
        (0x4A, 0x69, 107, .home),   // F14
        (0x65, 0x6A, 113, .menu),   // F15
        (0x35, 0x6B, 106, .tv),     // F16
        (0x66, 0x6C, 64,  .power),  // F17
        (0x28, 0x6D, 79,  .ok),     // F18
        // 方向键中转。F21-F24 在 macOS 没有虚拟键码（<HIToolbox/Events.h> 只到 kVK_F20，
        // 2026-07 对照本机 SDK 核实），映过去系统不产事件——不可用。
        // 故第 4 个中转用小键盘 Clear（usage 0x53 → kVK_ANSI_KeypadClear=71）：
        // macOS 无 NumLock 状态、系统零默认行为，即使 tap 失效泄漏也不输出字符。
        (0x52, 0x6E, 80,  .up),     // F19 (kVK_F19)
        (0x51, 0x6F, 90,  .down),   // F20 (kVK_F20)
        (0x50, 0x68, 105, .left),   // F13 (kVK_F13)
        (0x4F, 0x53, 71,  .right),  // Keypad Clear (kVK_ANSI_KeypadClear)
        // 音量键也需进入引擎：基础模式仍执行系统音量，AI 助手模式可复用为数字 2/3。
        // 选用少见的小键盘除/乘作为中转，避免与普通字母数字键冲突。
        (0x80, 0x54, 75,  .volUp),   // Keypad Divide
        (0x81, 0x55, 67,  .volDown), // Keypad Multiply
    ]

    /// 只静默、不送入 MappingEngine 的设备级映射。
    /// 遥控器语音键同时报告键盘 F5；终端会把 F5 的 ESC[15~ 序列显示成 `~`。
    /// 映射到 F21 usage 后 macOS 不产生键盘事件，真正的语音生命周期仍由 ATVV BLE 通道处理。
    private static let silentTable: [(src: UInt32, dst: UInt32)] = [
        (0x3E, 0x70), // voice/F5 → F21（macOS 无虚拟键码，静默）
    ]

    private static var mappingTable: [(src: UInt32, dst: UInt32)] {
        table.map { ($0.src, $0.dst) } + silentTable
    }

    /// 方向键 → 原生方向键 keycode（就地改写放行用）。
    static let nativeArrowKeycode: [RemoteKey: Int64] = [
        .up: 126, .down: 125, .left: 123, .right: 124,   // kVK_UpArrow 等
    ]

    /// 方向键中转的三态分流判定（纯函数，供 self-test）。非方向键返回 nil。
    enum DirectionVerdict: Equatable {
        case rewrite(Int64)   // 就地改写为原生方向键 keycode 放行（含 autorepeat）
        case drop             // 吞弃（引擎路径上的 autorepeat）
        case engine           // 吞掉并转 ButtonEvent 喂 MappingEngine
    }
    static func directionVerdict(key: RemoteKey, isRepeat: Bool, route: TapRoute) -> DirectionVerdict? {
        guard let arrow = nativeArrowKeycode[key] else { return nil }
        if route.effectiveLayer == 0, !route.okDown, route.nativeDirections.contains(key) {
            return .rewrite(arrow)
        }
        return isRepeat ? .drop : .engine
    }

    static var keycodeMap: [Int64: RemoteKey] {
        Dictionary(uniqueKeysWithValues: table.map { ($0.keycode, $0.key) })
    }

    // MARK: - hidutil 调用（install/uninstall/reinstall 可能来自不同线程，串行化）

    private static let matching = #"{"VendorID":0x2717,"ProductID":0x32B8}"#
    private static let hidutilLock = NSLock()
    /// install 前保存的设备原有映射（已剔除本进程自己的中转条目）。
    /// nil = 尚未成功读取（uninstall 按现状写空映射）。
    nonisolated(unsafe) private static var savedForeign: [(src: UInt64, dst: UInt64)]?

    /// 运行 hidutil，返回 (退出码==0, stdout)。启动失败/非零退出记日志。
    private static func runHidutil(_ args: [String], capture: Bool = false) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = capture ? pipe : FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            log?("hidutil 启动失败: \(error)")
            return (false, "")
        }
        let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            log?("hidutil 非零退出码 \(p.terminationStatus)（\(args.first(where: { $0 == "--set" }) != nil ? "set" : "get")）")
        }
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// 解析 `hidutil property --get UserKeyMapping` 的 plist 风格输出为 (src, dst) 对。
    /// 空输出 / (null) / 空数组 → []；有条目 → 逐块提取；输出非空但无法识别 → nil（解析失败）。
    static func parseUserKeyMapping(_ text: String) -> [(src: UInt64, dst: UInt64)]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if !trimmed.contains("{") {
            if trimmed.contains("(null)") { return [] }
            // 空数组：首个 "(" 与末尾 ")" 之间只有空白。
            if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"),
               open < close,
               trimmed[trimmed.index(after: open)..<close]
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return []
            }
            return nil
        }
        var pairs: [(src: UInt64, dst: UInt64)] = []
        var rest = Substring(trimmed)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            let block = rest[open...close]
            guard let src = number(after: "HIDKeyboardModifierMappingSrc", in: block),
                  let dst = number(after: "HIDKeyboardModifierMappingDst", in: block) else { return nil }
            pairs.append((src, dst))
            rest = rest[rest.index(after: close)...]
        }
        return pairs
    }

    private static func number(after key: String, in block: Substring) -> UInt64? {
        guard let r = block.range(of: key) else { return nil }
        let digits = block[r.upperBound...].drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return UInt64(digits)
    }

    /// 首次 install 前读取并保存设备现有映射。剔除本进程自己的中转条目
    /// （重复 install / 上次异常退出的残留不能被当成"原值"保存）。
    private static func saveExistingMappingIfNeeded() {
        guard savedForeign == nil else { return }
        let r = runHidutil(["property", "--matching", matching, "--get", "UserKeyMapping"], capture: true)
        guard r.ok, let pairs = parseUserKeyMapping(r.output) else {
            log?("读取设备现有 UserKeyMapping 失败或无法解析，uninstall 时将按空映射恢复")
            return
        }
        let ours = Set(mappingTable.map { 0x700000000 + UInt64($0.src) })
        let foreign = pairs.filter { !ours.contains($0.src) }
        savedForeign = foreign
        if !foreign.isEmpty { log?("已保存设备原有 UserKeyMapping \(foreign.count) 条，退出时恢复") }
    }

    private static func entryJSON(src: UInt64, dst: UInt64) -> String {
        #"{"HIDKeyboardModifierMappingSrc":\#(src),"HIDKeyboardModifierMappingDst":\#(dst)}"#
    }

    /// 安装重映射（幂等）。保留设备原有的第三方映射条目共存。
    @discardableResult
    static func install() -> Bool {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        saveExistingMappingIfNeeded()
        var entries = mappingTable.map {
            entryJSON(src: 0x700000000 + UInt64($0.src), dst: 0x700000000 + UInt64($0.dst))
        }
        entries += (savedForeign ?? []).map { entryJSON(src: $0.src, dst: $0.dst) }
        let ok = runHidutil(["property", "--matching", matching,
                             "--set", #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#]).ok
        if !ok { log?("hidutil 映射安装失败") }
        return ok
    }

    // MARK: - 稳定性专项消费接口（HealthMonitor 用：只读查询 + 异常退出残留清理）

    enum ResidueCleanResult: Equatable {
        case none            // 无本程序残留条目
        case cleaned(Int)    // 清理了 n 条残留（第三方条目原样保留）
        case queryFailed     // --get 失败或输出无法解析（遥控器不在场也走这里）
        case cleanFailed     // 有残留但 --set 回写失败
    }

    /// 启动时（安装映射前）/ --doctor 用：清除上次异常退出遗留的本程序中转条目，
    /// 保留第三方条目。映射在用时（tap 运行中）不要调用——在用映射不是残留。
    static func cleanResidualMapping() -> ResidueCleanResult {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        let r = runHidutil(["property", "--matching", matching, "--get", "UserKeyMapping"], capture: true)
        guard r.ok, let pairs = parseUserKeyMapping(r.output) else { return .queryFailed }
        let ours = Set(mappingTable.map { 0x700000000 + UInt64($0.src) })
        let residual = pairs.filter { ours.contains($0.src) }
        if residual.isEmpty { return .none }
        let entries = pairs.filter { !ours.contains($0.src) }
            .map { entryJSON(src: $0.src, dst: $0.dst) }
        let ok = runHidutil(["property", "--matching", matching,
                             "--set", #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#]).ok
        return ok ? .cleaned(residual.count) : .cleanFailed
    }

    /// 只读查询：本程序全部中转条目是否在位（nil = 查询/解析失败）。
    /// HealthMonitor 周期校验用，判据与 reinstall 相同（缺任何一条即缺失）。
    static func mappingPresent() -> Bool? {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        let r = runHidutil(["property", "--matching", matching, "--get", "UserKeyMapping"], capture: true)
        guard r.ok, let pairs = parseUserKeyMapping(r.output) else { return nil }
        let present = Set(pairs.map(\.src))
        return mappingTable.allSatisfy { present.contains(0x700000000 + UInt64($0.src)) }
    }

    /// 恢复设备原有映射（install 前保存的值；读取/解析失败时按空映射恢复，即现状行为）。
    @discardableResult
    static func uninstall() -> Bool {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        let entries = (savedForeign ?? []).map { entryJSON(src: $0.src, dst: $0.dst) }
        let ok = runHidutil(["property", "--matching", matching,
                             "--set", #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#]).ok
        if !ok { log?("hidutil 映射恢复失败") }
        return ok
    }
}

/// CGEventTap：捕获中转键（F13-F20/小键盘Clear），吞掉并转成 ButtonEvent。
/// 需要「辅助功能」权限。复用 HIDEngineDelegate 契约。
///
/// 失效安全（Codex 加固）：tap 被禁用（超时/用户输入）或健康检查发现失效时，
/// 先尝试重启；重启失败立即卸载 hidutil 映射——绝不允许「映射在、过滤器不在」
/// 的中转键泄漏态；tap 恢复后由健康检查自动重装映射。
final class TapEngine: @unchecked Sendable {

    weak var delegate: HIDEngineDelegate?
    /// 方向键分流的快照来源（MappingEngine）。nil 时方向键全走引擎路径（安全默认）。
    weak var router: MappingEngine?
    private var tap: CFMachPort?

    /// 按压锁存（tap 回调线程写，健康检查/复位线程可能清空，锁保护）。
    private struct PressState {
        /// 当前按压走「原生改写放行」路径的方向键。
        var nativeHeld: Set<RemoteKey> = []
        /// OK 键物理按住（tap 回调同步维护——OK 是中转键，回调能同步看到；
        /// 方向键分流用它替代快照里的异步 okDown，消掉手势漏判窗口）。
        var okDown = false
        /// hidutil 映射当前是否已安装（失效安全的恢复判据）。
        var mappingInstalled = false
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: PressState())

    /// 低频健康检查：tap 可能被系统静默禁用（辅助功能撤权等），每 30s 校验一次。
    private var healthTimer: DispatchSourceTimer?
    private let healthQueue = DispatchQueue(label: "com.miremote.taphealth")

    init(delegate: HIDEngineDelegate?) {
        self.delegate = delegate
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.tapDisabledByTimeout.rawValue)
                              | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, ev, userInfo in
                let me = Unmanaged<TapEngine>.fromOpaque(userInfo!).takeUnretainedValue()
                return me.handle(type: type, event: ev)
            },
            userInfo: selfPtr) else {
            delegate?.hidLog("TAP 创建失败（需辅助功能权限），清理可能残留的 hidutil 映射")
            KeyRemapper.uninstall()   // 上次异常退出可能残留映射；tap 起不来绝不留映射
            delegate?.hidSeizeState(false)
            return
        }
        self.tap = tap
        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let installed = KeyRemapper.install()
        stateLock.withLock { $0.mappingInstalled = installed }
        startHealthTimer()
        delegate?.hidSeizeState(true)
        delegate?.hidLog(installed ? "TAP 就绪，hidutil 中转映射已安装"
                                   : "TAP 就绪，但 hidutil 映射安装失败（中转键位不生效）")
    }

    func stop() {
        healthTimer?.cancel()
        healthTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        KeyRemapper.uninstall()
        stateLock.withLock { $0 = PressState() }
    }

    /// 幂等重装 hidutil 映射（蓝牙重连 / 系统唤醒后调用：设备服务重建后映射可能失效）。
    /// tap 未运行时不做事（避免制造「映射在、过滤器不在」泄漏态）。
    func reinstallMapping(reason: String) {
        healthQueue.async { [weak self] in
            guard let self, self.tap != nil else { return }
            let ok = KeyRemapper.install()
            self.stateLock.withLock { $0.mappingInstalled = ok }
            self.delegate?.hidLog(ok ? "hidutil 映射已重装（\(reason)）"
                                     : "hidutil 映射重装失败（\(reason)）")
        }
    }

    /// 清空按压锁存（OK 物理态 / 原生按住方向）。设备移除、系统睡眠、tap 失效恢复时调用。
    func resetPressState() {
        stateLock.withLock { st in
            st.nativeHeld.removeAll()
            st.okDown = false
        }
    }

    // MARK: - 失效安全

    private func startHealthTimer() {
        let t = DispatchSource.makeTimerSource(queue: healthQueue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.healthCheck() }
        t.resume()
        healthTimer = t
    }

    private func healthCheck() {
        guard let tap else { return }
        let installed = stateLock.withLock { $0.mappingInstalled }
        if CGEvent.tapIsEnabled(tap: tap) {
            // tap 健康。若此前因失效卸载过映射，恢复后自动重装。
            if !installed, KeyRemapper.install() {
                stateLock.withLock { $0.mappingInstalled = true }
                delegate?.hidLog("健康检查：TAP 已恢复，hidutil 映射已重装")
            }
            return
        }
        delegate?.hidLog("健康检查：TAP 已失效，尝试恢复")
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            delegate?.hidLog("健康检查：TAP 已重新启用")
            resetPressState()
            router?.resetInputState(reason: "健康检查恢复 tap")
        } else if installed {
            KeyRemapper.uninstall()
            stateLock.withLock { $0.mappingInstalled = false }
            resetPressState()
            router?.resetInputState(reason: "tap 失效")
            delegate?.hidLog("健康检查：TAP 无法恢复，已卸载 hidutil 映射防止中转键泄漏（恢复后自动重装）")
            delegate?.hidSeizeState(false)
        }
    }

    /// tap 被系统禁用（超时/用户输入）后的恢复：重启成功则复位输入状态
    /// （禁用期间可能丢 keyUp）；失败立即卸载映射。
    private func recoverDisabledTap(_ reason: String) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            delegate?.hidLog("TAP 被禁用（\(reason)），已重新启用")
            resetPressState()
            router?.resetInputState(reason: "tap 重启")
        } else {
            delegate?.hidLog("TAP 被禁用（\(reason)）且重启失败，卸载 hidutil 映射防止中转键泄漏")
            KeyRemapper.uninstall()
            stateLock.withLock { $0.mappingInstalled = false }
            resetPressState()
            router?.resetInputState(reason: "tap 失效")
            delegate?.hidSeizeState(false)
        }
    }

    // MARK: - 事件回调

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverDisabledTap(type == .tapDisabledByTimeout ? "超时" : "用户输入")
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = KeyRemapper.keycodeMap[keycode] else {
            return Unmanaged.passUnretained(event) // 非中转键，放行
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // OK 物理态同步锁存：OK 是中转键，回调在这里能同步看到它的 down/up；
        // 方向键分流判定用锁存值覆盖快照里的异步 okDown，消掉「OK↓与方向↓几乎同时」
        // 时快照来不及更新导致的手势漏判窗口。
        if key == .ok, !isRepeat {
            stateLock.withLock { $0.okDown = (type == .keyDown) }
        }

        // 方向键三态分流：纯原生场景就地改写 keycode 放行（保住系统 autorepeat 与零延迟）。
        // 分流只在首次 keyDown 时决定（层/纯原生判定读 MappingEngine 快照，okDown 用本地
        // 同步锁存值）；autorepeat 与 keyUp 跟随该次按压记录的路径，避免按压中途层变化导致
        // 原生 down 配不上 up（系统卡住方向键）或引擎收到孤儿 up。
        if let arrow = KeyRemapper.nativeArrowKeycode[key] {
            let verdict: KeyRemapper.DirectionVerdict = stateLock.withLock { st in
                if type == .keyDown, !isRepeat {
                    var route = router?.tapRoute ?? TapRoute()
                    route.okDown = st.okDown
                    let v = KeyRemapper.directionVerdict(key: key, isRepeat: false, route: route)!
                    if case .rewrite = v { st.nativeHeld.insert(key) } else { st.nativeHeld.remove(key) }
                    return v
                }
                let wasNative = st.nativeHeld.contains(key)
                if type == .keyUp { st.nativeHeld.remove(key) }
                return wasNative ? .rewrite(arrow) : (isRepeat ? .drop : .engine)
            }
            switch verdict {
            case .rewrite(let a):
                event.setIntegerValueField(.keyboardEventKeycode, value: a)
                return Unmanaged.passUnretained(event)
            case .drop:
                return nil
            case .engine:
                // 落到下方吞掉上报
                break
            }
        } else if isRepeat {
            // 非方向中转键的 autorepeat 也吞弃：重复 keyDown 会不断重置
            // MappingEngine 的 hold 定时器，长按（如 ok→瞬时层）永远触发不了。
            return nil
        }
        // 吞掉中转键并上报（注意：外接键盘的真 F13-F20/小键盘Clear 也会被吞——Mac 键盘几乎没有这些键，可接受）
        delegate?.hidButton(ButtonEvent(key: key, isDown: type == .keyDown,
                                        timeNs: DispatchTime.now().uptimeNanoseconds))
        return nil
    }
}
