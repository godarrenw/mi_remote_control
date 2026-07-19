import Foundation

// ponytail: CLT 不带 XCTest/Swift Testing，测试编进二进制用 --self-test 跑；装了 Xcode 后可迁回 testTarget

/// 测试内的标准 IMA ADPCM 编码器，与被测解码器共用步长/索引表，
/// 用来构造已知向量：正弦波 → 编码 → 解码 → 比对 RMS 误差。
private struct IMAEncoder {
    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
        3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8]

    var predictor: Int32 = 0
    var stepIndex: Int = 0

    mutating func reset(predictor: Int16, stepIndex: Int) {
        self.predictor = Int32(predictor)
        self.stepIndex = min(max(stepIndex, 0), 88)
    }

    mutating func encodeNibble(_ sample: Int16) -> UInt8 {
        let step = IMAEncoder.stepTable[stepIndex]
        var diff = Int32(sample) - predictor
        var nibble: UInt8 = 0
        if diff < 0 { nibble = 0x08; diff = -diff }

        var tempStep = step
        if diff >= tempStep { nibble |= 0x04; diff -= tempStep }
        tempStep >>= 1
        if diff >= tempStep { nibble |= 0x02; diff -= tempStep }
        tempStep >>= 1
        if diff >= tempStep { nibble |= 0x01 }

        var predDiff = step >> 3
        if nibble & 4 != 0 { predDiff += step }
        if nibble & 2 != 0 { predDiff += step >> 1 }
        if nibble & 1 != 0 { predDiff += step >> 2 }
        predictor += (nibble & 0x08 != 0) ? -predDiff : predDiff
        predictor = min(max(predictor, -32768), 32767)

        stepIndex += IMAEncoder.indexTable[Int(nibble & 0x07)]
        stepIndex = min(max(stepIndex, 0), 88)
        return nibble
    }

    mutating func encode(_ samples: [Int16]) -> Data {
        var data = Data()
        var i = 0
        while i + 1 < samples.count {
            let hi = encodeNibble(samples[i])
            let lo = encodeNibble(samples[i + 1])
            data.append((hi << 4) | lo)
            i += 2
        }
        return data
    }
}

private func rms(_ a: [Int16], _ b: [Int16]) -> Double {
    precondition(a.count == b.count)
    var acc = 0.0
    for i in 0..<a.count {
        let d = Double(a[i]) - Double(b[i])
        acc += d * d
    }
    return (a.isEmpty ? 0 : (acc / Double(a.count)).squareRoot())
}

enum SelfTest {
    private static var failures = 0

    private static func expect(_ cond: Bool, _ name: String, _ detail: String = "") {
        if cond {
            print("  ok  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func run() -> Int32 {
        // 1. 正弦波 round-trip：RMS 误差应在满量程 5% 以内
        do {
            let n = 4000
            var sine = [Int16]()
            let amp = 20000.0
            for i in 0..<n {
                sine.append(Int16(amp * sin(2.0 * Double.pi * Double(i) * 300.0 / 16000.0)))
            }
            var enc = IMAEncoder()
            enc.reset(predictor: sine[0], stepIndex: 0)
            let encoded = enc.encode(sine)
            let dec = ADPCMDecoder()
            dec.reset(predictor: sine[0], stepIndex: 0)
            let decoded = dec.decode(encoded)
            expect(decoded.count == encoded.count * 2, "sine 解码样本数")
            let error = rms(Array(sine.prefix(decoded.count)), decoded)
            expect(error / 65535.0 < 0.05, "sine RMS 误差", "rms=\(error)")
        }

        // 2. reset 后从同步值继续解码
        do {
            var enc = IMAEncoder()
            enc.reset(predictor: 1000, stepIndex: 10)
            let samples: [Int16] = [1200, 1500, 900, 300, -200, -800, -100, 400]
            let encoded = enc.encode(samples)
            let dec = ADPCMDecoder()
            dec.reset(predictor: -5000, stepIndex: 50)
            _ = dec.decode(Data([0x12, 0x34, 0x56]))
            dec.reset(predictor: 1000, stepIndex: 10)
            let decoded = dec.decode(encoded)
            expect(rms(samples, decoded) < 200, "resync 闭环误差")
        }

        // 3. nibble 顺序：高 nibble 先解
        do {
            let dec = ADPCMDecoder()
            dec.reset(predictor: 0, stepIndex: 0)
            let decoded = dec.decode(Data([0xAB]))
            expect(decoded.count == 2, "0xAB 解出两样本")
            expect(decoded.count == 2 && decoded[0] < 0, "高 nibble 0xA 先解出负样本")
            var predictor: Int32 = 0
            var stepIndex = 0
            func ref(_ nib: UInt8) -> Int16 {
                let step = IMAEncoder.stepTable[stepIndex]
                var diff = step >> 3
                if nib & 4 != 0 { diff += step }
                if nib & 2 != 0 { diff += step >> 1 }
                if nib & 1 != 0 { diff += step >> 2 }
                predictor += (nib & 0x08 != 0) ? -diff : diff
                predictor = min(max(predictor, -32768), 32767)
                stepIndex += IMAEncoder.indexTable[Int(nib & 0x07)]
                stepIndex = min(max(stepIndex, 0), 88)
                return Int16(predictor)
            }
            expect(decoded[0] == ref(0xA) && decoded[1] == ref(0xB), "nibble 逐步参考对照")
        }

        // 4. FrameAccumulator：1 字节一包
        do {
            var acc = FrameAccumulator(frameSize: 4)
            var frames = [Data]()
            for b in [UInt8(1), 2, 3, 4, 5, 6, 7, 8, 9] {
                frames.append(contentsOf: acc.append(Data([b])))
            }
            expect(frames.count == 2 && Array(frames[0]) == [1, 2, 3, 4] && Array(frames[1]) == [5, 6, 7, 8],
                   "FrameAccumulator 逐字节重组")
        }

        // 5. FrameAccumulator：粘包 + 余量
        do {
            var acc = FrameAccumulator(frameSize: 3)
            let frames = acc.append(Data([1, 2, 3, 4, 5, 6, 7]))
            let more = acc.append(Data([8, 9]))
            expect(frames.count == 2 && Array(frames[0]) == [1, 2, 3] && Array(frames[1]) == [4, 5, 6]
                   && more.count == 1 && Array(more[0]) == [7, 8, 9], "FrameAccumulator 粘包/余量")
        }

        // 6. stepIndex 上界 clamp
        do {
            let dec = ADPCMDecoder()
            dec.reset(predictor: 0, stepIndex: 80)
            let decoded = dec.decode(Data(repeating: 0x77, count: 50))
            expect(decoded.count == 100 && decoded.last == 32767, "stepIndex 上界 clamp + 样本饱和")
        }

        // 7. stepIndex 下界 clamp
        do {
            let dec = ADPCMDecoder()
            dec.reset(predictor: 0, stepIndex: -10)
            expect(dec.decode(Data([0x00, 0x00])).count == 4, "stepIndex 下界 clamp")
        }

        // 8. PCMPostprocessor 平滑跨批连续
        do {
            let pp = PCMPostprocessor(gainDB: 0)
            let b1 = pp.process([100, 200, 300])
            let b2 = pp.process([400, 500])
            expect(b1.count == 3 && b2.count == 2 && b2[0] == 300, "平滑跨批连续", "b2[0]=\(b2.first.map(String.init) ?? "-")")
        }

        // 9. PCMPostprocessor 增益 clamp
        do {
            let pp = PCMPostprocessor(gainDB: 40)
            let out = pp.process([1000, 1000, 1000])
            expect(out.count == 3 && out.last == 32767, "增益放大 clamp")
        }

        // M2 模块自测
        expect(MappingEngine.selfCheck(), "MappingEngine 状态机自测")
        expect(ActionRunner.selfCheck(), "ActionRunner 键表/修饰位自测")

        // M4-1. Action JSON 编解码往返（全部新旧 case）
        do {
            let actions: [Action] = [
                .keyStroke(key: "a", mods: ["left_cmd"]), .system("mute"),
                .openApp("com.apple.Terminal"), .shell("true"), .voice,
                .layerMomentary(1), .layerToggle(2), .none,
                .windowCycle(scope: "app"), .windowCycle(scope: "global"),
                .tabJump(dir: 1, index: nil), .tabJump(dir: -1, index: nil), .tabJump(dir: nil, index: 3),
                .focusInput, .mouseMode,
                .macro(steps: [.action(.keyStroke(key: "return", mods: [])),
                               .delay(ms: 100), .text("hello 世界"),
                               .action(.macro(steps: [.text("x")]))]),
            ]
            var bad: String? = nil
            for a in actions {
                let back = try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(a))
                if back != a { bad = "\(a)"; break }
            }
            expect(bad == nil, "Action JSON 往返", bad ?? "")
        } catch { expect(false, "Action JSON 往返", "\(error)") }

        // M4-2. 新格式 JSON 字面量解析（scope 省略默认 app；macro 混合步骤）
        do {
            let d = JSONDecoder()
            expect(try d.decode(Action.self, from: Data(#"{"type":"window_cycle"}"#.utf8))
                       == .windowCycle(scope: "app"), "window_cycle 无 scope 默认 app")
            expect(try d.decode(Action.self, from: Data(#"{"type":"tab_jump","index":2}"#.utf8))
                       == .tabJump(dir: nil, index: 2), "tab_jump index 模式解析")
            let macroJSON = #"{"type":"macro","steps":[{"type":"focus_input"},{"type":"delay","ms":50},{"type":"text","value":"hi"},{"type":"key_stroke","key":"return"}]}"#
            expect(try d.decode(Action.self, from: Data(macroJSON.utf8))
                       == .macro(steps: [.action(.focusInput), .delay(ms: 50), .text("hi"),
                                         .action(.keyStroke(key: "return", mods: []))]),
                   "macro 混合步骤 JSON 解析")
        } catch { expect(false, "M4 新格式 JSON 解析", "\(error)") }

        // M4-3. 旧配置 JSON 向后兼容（M2 生成的 config.json 结构原样解析）
        do {
            let legacy = #"""
            {"version":1,"settings":{"holdMs":350,"doubleMs":0},"profiles":{"global":{
              "ok":{"tap":{"type":"key_stroke","key":"return","mods":[]}},
              "menu":{"tap":{"type":"system","value":"mission_control"}},
              "tv":{"tap":{"type":"open_app","value":"com.apple.systempreferences"}},
              "voice":{"tap":{"type":"voice"}}}}}
            """#
            let cfg = try JSONDecoder().decode(MappingConfig.self, from: Data(legacy.utf8))
            expect(cfg.profiles["global"]?["ok"]?.tap == .keyStroke(key: "return", mods: [])
                   && cfg.profiles["global"]?["menu"]?.tap == .system("mission_control")
                   && cfg.profiles["global"]?["voice"]?.tap == .voice,
                   "旧配置 JSON 向后兼容")
        } catch { expect(false, "旧配置 JSON 向后兼容", "\(error)") }

        // M4-4. Macro 步骤序列纯逻辑（假 primitives 记录顺序与延时；嵌套限深 1 层）
        do {
            final class Recorder: MacroPrimitives {
                var log: [String] = []
                func perform(_ action: Action) { log.append("act(\(actionTag(action)))") }
                func typeText(_ text: String) { log.append("text(\(text))") }
                func wait(ms: Int) { log.append("wait(\(ms))") }
                private func actionTag(_ a: Action) -> String {
                    if case .keyStroke(let k, _) = a { return k }
                    return "?"
                }
            }
            let steps: [MacroStep] = [
                .action(.keyStroke(key: "a", mods: [])),
                .delay(ms: 50),
                .text("hi"),
                .action(.macro(steps: [.text("in"),
                                       .action(.macro(steps: [.text("deep")]))])), // 第 2 层应被忽略
            ]
            let rec = Recorder()
            MacroEngine.execute(steps, primitives: rec, depth: 0)
            expect(rec.log == ["act(a)", "wait(20)", "wait(50)", "wait(20)", "text(hi)",
                               "wait(20)", "text(in)", "wait(20)"],
                   "Macro 步骤顺序/间隔/嵌套限深", "\(rec.log)")
        }

        // M4-5. MouseMode 加速曲线纯函数
        expect(MouseMode.speed(afterSeconds: 0) == 4.0, "MouseMode 初速 4px/tick")
        expect(abs(MouseMode.speed(afterSeconds: 0.75) - 22.0) < 0.001, "MouseMode 中点 22px/tick")
        expect(MouseMode.speed(afterSeconds: 1.5) == 40.0, "MouseMode 1.5s 满速 40px/tick")
        expect(MouseMode.speed(afterSeconds: 10) == 40.0, "MouseMode 满速封顶")
        expect(MouseMode.speed(afterSeconds: -1) == 4.0, "MouseMode 负时长取初速")

        // M4-6. MouseMode 方向向量（对角线/相消）
        do {
            let d1 = MouseMode.delta(dirs: [.up, .right], speed: 10)
            expect(d1.dx == 10 && d1.dy == -10, "MouseMode 对角线向量")
            let d2 = MouseMode.delta(dirs: [.left, .right], speed: 10)
            expect(d2.dx == 0 && d2.dy == 0, "MouseMode 反向相消")
        }

        // M4-7. FocusInput 终端白名单判定
        expect(FocusInput.isTerminalApp("com.mitchellh.ghostty")
               && FocusInput.isTerminalApp("com.apple.Terminal")
               && FocusInput.isTerminalApp("com.googlecode.iterm2"), "FocusInput 终端白名单命中")
        expect(!FocusInput.isTerminalApp("com.google.Chrome")
               && !FocusInput.isTerminalApp(nil), "FocusInput 非终端/空 bundle 判非")

        // M4-8. WindowSwitcher 纯逻辑（循环下标 + 全局目标挑选）
        expect(WindowSwitcher.nextIndex(after: 0, count: 3) == 1
               && WindowSwitcher.nextIndex(after: 2, count: 3) == 0
               && WindowSwitcher.nextIndex(after: 5, count: 0) == 0, "WindowSwitcher 循环下标")
        do {
            typealias W = WindowSwitcher.WindowInfo
            let wins = [W(pid: 1, windowID: 11, title: "front"),
                        W(pid: 2, windowID: 22, title: ""),
                        W(pid: 3, windowID: 33, title: "titled")]
            expect(WindowSwitcher.pickGlobalTarget(wins)?.windowID == 33, "全局切换有标题优先")
            expect(WindowSwitcher.pickGlobalTarget([wins[0], wins[1]])?.windowID == 22, "全局切换无标题兜底")
            expect(WindowSwitcher.pickGlobalTarget([wins[0]]) == nil, "单窗口不切换")
        }

        print(failures == 0 ? "SELF-TEST PASS" : "SELF-TEST FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
