import Foundation
import CoreGraphics

/// 宏步骤执行原语。生产实现 LiveMacroPrimitives 真正合成事件；
/// 自检注入假实现记录调用序列（纯逻辑单测）。
protocol MacroPrimitives {
    func perform(_ action: Action)
    func typeText(_ text: String)
    func wait(ms: Int)
}

/// 宏执行器（DESIGN §3.2 macro）：
///   - 后台串行 queue 顺序执行 steps（action / delay_ms / text）；
///   - 单步之间默认 20ms 间隔（显式 delay 步骤额外累加）；
///   - 防重入：宏执行中再触发宏 → 忽略并 log；
///   - 嵌套限深：宏里嵌宏最多 1 层，再深忽略并 log（嵌套宏内联执行，不走防重入闸门）。
final class MacroEngine: @unchecked Sendable {
    static let shared = MacroEngine()

    static let interStepMs = 20
    static let maxDepth = 1

    private let q = DispatchQueue(label: "com.miremote.macro")
    private let lock = NSLock()
    private var running = false

    /// 是否有宏在执行中（--run-action 等待宏完成再退出用）。
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 触发一段宏（异步，不阻塞调用方）。执行中重入直接忽略。
    func run(_ steps: [MacroStep], runner: ActionRunning) {
        lock.lock()
        if running {
            lock.unlock()
            NSLog("[Macro] 已有宏在执行，忽略本次触发")
            return
        }
        running = true
        lock.unlock()
        q.async { [weak self] in
            MacroEngine.execute(steps, primitives: LiveMacroPrimitives(runner: runner), depth: 0)
            guard let self else { return }
            self.lock.lock()
            self.running = false
            self.lock.unlock()
        }
    }

    /// 纯逻辑：顺序执行步骤（步骤间隔/嵌套限深都在这里，可注入假 primitives 单测）。
    static func execute(_ steps: [MacroStep], primitives: MacroPrimitives, depth: Int) {
        for (i, step) in steps.enumerated() {
            if i > 0 { primitives.wait(ms: interStepMs) }
            switch step {
            case .delay(let ms):
                primitives.wait(ms: ms)
            case .text(let s):
                primitives.typeText(s)
            case .action(.macro(let inner)):
                if depth >= maxDepth {
                    NSLog("[Macro] 嵌套宏超过 %d 层，忽略", maxDepth)
                } else {
                    execute(inner, primitives: primitives, depth: depth + 1)
                }
            case .action(let a):
                primitives.perform(a)
            }
        }
    }
}

/// 生产原语：action 回主线程交给 ActionRunner；text 用 keyboardSetUnicodeString 分段发。
private struct LiveMacroPrimitives: MacroPrimitives {
    let runner: ActionRunning

    func perform(_ action: Action) {
        // MappingEngine 契约是主线程调 run；宏在后台 queue，回主线程保持一致。
        DispatchQueue.main.sync { runner.run(action) }
    }

    func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + chunkSize, utf16.count)])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            i += chunkSize
            if i < utf16.count { usleep(8_000) } // 分段间隙，防长文本丢字
        }
    }

    func wait(ms: Int) {
        // 解码层已把 delay 限制在 0...60_000；这里仍做饱和转换兜底（防负数/
        // 乘法溢出 trap——任意来源的 Action 不能让整个进程崩溃）。
        guard ms > 0 else { return }
        usleep(min(useconds_t(clamping: ms), 60_000) * 1000)
    }
}
