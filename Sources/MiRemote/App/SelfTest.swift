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
        expect(MappingEngine.tapRouteSelfCheck(), "M3 方向键分流快照/判定自测")
        expect(ActionRunner.selfCheck(), "ActionRunner 键表/修饰位自测")
        expect(WorkspaceActions.selfCheck(), "WorkspaceActions 工作区动作目录自测")
        expect(Set(KeyRemapper.table.map(\.key)).isSuperset(of: [.volUp, .volDown]),
               "音量键进入映射引擎（基础音量 / AI 数字 2、3）")

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

        // Presets-1. 所有预设的每个 KeyBinding 能被 JSONEncoder/Decoder 无损往返
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            let dec = JSONDecoder()
            var bad: String? = nil
            outer: for preset in Presets.all {
                for (key, binding) in preset.bindings {
                    let d1 = try enc.encode(binding)
                    let d2 = try enc.encode(dec.decode(KeyBinding.self, from: d1))
                    if d1 != d2 { bad = "\(preset.id).\(key)"; break outer }
                }
            }
            expect(bad == nil, "预设 KeyBinding JSON 往返", bad ?? "")
        } catch { expect(false, "预设 KeyBinding JSON 往返", "\(error)") }

        // Presets-2. 预设内所有 key_stroke 的键名/修饰名都在 ActionRunner 表内（防拼错）
        do {
            func collectKeyStrokes(_ a: Action, into out: inout [(String, [String])]) {
                switch a {
                case .keyStroke(let k, let m): out.append((k, m))
                case .macro(let steps):
                    for s in steps { if case .action(let inner) = s { collectKeyStrokes(inner, into: &out) } }
                default: break
                }
            }
            var badName: String? = nil
            outer: for preset in Presets.all {
                for (key, binding) in preset.bindings {
                    var strokes = [(String, [String])]()
                    for act in Presets.actions(in: binding) { collectKeyStrokes(act, into: &strokes) }
                    for (k, mods) in strokes {
                        if ActionRunner.keyCodes[k.lowercased()] == nil {
                            badName = "\(preset.id).\(key) 未知键名 '\(k)'"; break outer
                        }
                        for m in mods where ActionRunner.modifiers[m.lowercased()] == nil {
                            badName = "\(preset.id).\(key) 未知修饰 '\(m)'"; break outer
                        }
                    }
                }
            }
            expect(badName == nil, "预设键名/修饰名全部有效", badName ?? "")
        }

        // Presets-3. apply 合并语义：空配置写入 / 不覆盖用户绑定 / force 覆盖 / 层槽合并
        do {
            // (a) 空配置：per-app 预设写进对应 bundle profile
            var cfg = MappingConfig()
            Presets.apply(Presets.iina, to: &cfg)
            expect(cfg.profiles["com.colliderli.iina"]?["ok"]?.tap == .keyStroke(key: "space", mods: []),
                   "apply 空配置写入 per-app")

            // (b) 不覆盖用户已设的同一槽位，但补齐用户未设的槽
            var cfg2 = MappingConfig()
            cfg2.profiles["com.colliderli.iina"] = ["ok": KeyBinding(tap: .system("mute"))]
            Presets.apply(Presets.iina, to: &cfg2)   // 预设 ok.tap=space，与用户冲突
            expect(cfg2.profiles["com.colliderli.iina"]?["ok"]?.tap == .system("mute"),
                   "apply 不覆盖用户已有槽位")
            expect(cfg2.profiles["com.colliderli.iina"]?["up"]?.tap == .keyStroke(key: "f", mods: []),
                   "apply 仍补齐用户未设的键")

            // (c) force=true 覆盖用户绑定
            var cfg3 = MappingConfig()
            cfg3.profiles["com.colliderli.iina"] = ["ok": KeyBinding(tap: .system("mute"))]
            Presets.apply(Presets.iina, to: &cfg3, force: true)
            expect(cfg3.profiles["com.colliderli.iina"]?["ok"]?.tap == .keyStroke(key: "space", mods: []),
                   "apply force 覆盖用户绑定")

            // (d) 层绑定类并入 global 的 layers["2"]，不动用户已有 base tap
            var cfg4 = MappingConfig()
            cfg4.profiles["global"] = ["ok": KeyBinding(tap: .keyStroke(key: "return", mods: []))]
            Presets.apply(Presets.aiApprovalLayer, to: &cfg4)
            expect(cfg4.profiles["global"]?["ok"]?.tap == .keyStroke(key: "return", mods: []),
                   "层预设保留 base tap")
            expect(cfg4.profiles["global"]?["ok"]?.layers?["2"] == .keyStroke(key: "return", mods: []),
                   "层预设写入 layers[2]")
            expect(cfg4.profiles["global"]?["menu"]?.layers?["2"] == .keyStroke(key: "tab", mods: ["left_shift"]),
                   "层预设 Shift+Tab 切自动模式")

            // (e) 两个层预设叠加，各自的 layer[2] 键互不覆盖
            Presets.apply(Presets.multiAgentBindings, to: &cfg4)
            expect(cfg4.profiles["global"]?["left"]?.layers?["2"] == .tabJump(dir: -1, index: nil)
                   && cfg4.profiles["global"]?["right"]?.layers?["2"] == .tabJump(dir: 1, index: nil),
                   "多 agent 层预设叠加到 layer[2]")
        }

        // Presets-4. v1 老配置只迁移一次：保留用户手势，补齐 Profile/导航入口与可用双击窗口。
        do {
            var legacy = MappingConfig()
            legacy.version = 1
            legacy.settings.doubleMs = 50
            legacy.profiles["global"] = [
                "menu": KeyBinding(tap: .system("display_sleep")),
                "ok": KeyBinding(gesture: ["up": .openApp("com.example.custom")]),
            ]
            let migrated = migrateConfigIfNeeded(legacy)
            expect(migrated.version == MappingConfig.currentVersion
                   && migrated.settings.doubleMs == 300
                   && migrated.profiles["global"]?["menu"]?.tap == .layerToggle(3),
                   "v1 迁移版本/导航入口/双击窗口")
            expect(migrated.profiles["global"]?["ok"]?.gesture?["up"] == .openApp("com.example.custom")
                   && migrated.profiles["global"]?["ok"]?.gesture?["down"] == .windowCycle(scope: "app"),
                   "v1 迁移保留用户手势并补空位")
            expect(migrated.profiles["com.mitchellh.ghostty"] != nil
                   && migrated.profiles["com.openai.codex"] != nil
                   && migrated.profiles["com.google.Chrome"] != nil
                   && migrated.profiles["com.apple.Safari"] != nil
                   && migrated.profiles["com.anthropic.claudefordesktop"] != nil
                   && migrated.profiles["com.tencent.xinWeChat"] != nil,
                   "v1 迁移补齐六个高频 Profile")

            var alreadyV2 = migrated
            alreadyV2.version = 2
            alreadyV2.voiceProfiles = nil
            alreadyV2.profiles.removeValue(forKey: "com.mitchellh.ghostty")
            let migratedV3 = migrateConfigIfNeeded(alreadyV2)
            expect(migratedV3.profiles["com.mitchellh.ghostty"] == nil,
                   "v2→v3 不补回用户删除的 Profile")
            expect(migratedV3.version == 3
                   && migratedV3.voiceProfiles?["global"] == VoiceTriggerRule(),
                   "v2→v3 补全全局语音触发规则")

            var voiceRules = migratedV3.voiceProfiles ?? [:]
            voiceRules["com.example.writer"] = VoiceTriggerRule(
                keyName: "f13", mode: "tap", imeBundlePrefix: nil)
            let appVoice = VoiceTriggerRouting.resolve(voiceRules, bundleID: "com.example.writer")
            let inheritedVoice = VoiceTriggerRouting.resolve(voiceRules, bundleID: "com.example.other")
            expect(appVoice == VoiceTriggerConfig(keyName: "f13", mode: .tap, imeBundlePrefix: nil),
                   "语音快捷键按 App 覆盖")
            expect(inheritedVoice == VoiceTriggerConfig(), "未配置 App 继承全局语音快捷键")
            voiceRules["com.example.bad"] = VoiceTriggerRule(
                keyName: "invalid", mode: "invalid", imeBundlePrefix: nil)
            let safeVoice = VoiceTriggerRouting.resolve(voiceRules, bundleID: "com.example.bad")
            expect(safeVoice.keyName == "right_option" && safeVoice.mode == .hold,
                   "坏语音按键/模式安全回退")
        }

        // 加固-1. Action 严格解码：未知 type 抛错（拼写错误不再伪装成 .none），显式 none 正常。
        do {
            let d = JSONDecoder()
            expect((try? d.decode(Action.self, from: Data(#"{"type":"warp_drive"}"#.utf8))) == nil,
                   "Action 未知 type 抛解码错误")
            expect((try? d.decode(Action.self, from: Data(#"{"type":"none"}"#.utf8))) == Action.none,
                   "Action 显式 none 正常解码")
            expect((try? d.decode(MacroStep.self, from: Data(#"{"type":"warp_drive"}"#.utf8))) == nil,
                   "MacroStep 未知 type 抛解码错误")
            expect((try? d.decode(MappingConfig.self, from: Data(
                #"{"version":1,"settings":{"holdMs":350,"doubleMs":0},"profiles":{"global":{"ok":{"tap":{"type":"tpyo"}}}}}"#.utf8))) == nil,
                   "含未知动作的整份配置解码失败（触发 main 回退默认配置）")
        }

        // 加固-2. hidutil UserKeyMapping 输出解析（install 保存前值 / uninstall 恢复用）
        do {
            expect(KeyRemapper.parseUserKeyMapping("")?.isEmpty == true, "空输出 → 空映射")
            expect(KeyRemapper.parseUserKeyMapping("RegistryID  Key  Value\n100001209 UserKeyMapping (null)\n")?.isEmpty == true,
                   "(null) → 空映射")
            expect(KeyRemapper.parseUserKeyMapping("100001209 UserKeyMapping (\n)\n")?.isEmpty == true,
                   "空数组 → 空映射")
            // 实机 --get 输出原样（含表头、缩进）
            let sample = """
            RegistryID  Key                   Value
            100001209   UserKeyMapping   (
                    {
                    HIDKeyboardModifierMappingDst = 30064771177;
                    HIDKeyboardModifierMappingSrc = 30064771146;
                },
                    {
                    HIDKeyboardModifierMappingDst = 30064771178;
                    HIDKeyboardModifierMappingSrc = 30064771173;
                }
            )
            """
            let pairs = KeyRemapper.parseUserKeyMapping(sample)
            expect(pairs?.count == 2
                   && pairs?[0].src == 30064771146 && pairs?[0].dst == 30064771177
                   && pairs?[1].src == 30064771173 && pairs?[1].dst == 30064771178,
                   "plist 风格条目解析", "\(String(describing: pairs))")
            expect(KeyRemapper.parseUserKeyMapping("hidutil: unexpected error") == nil,
                   "无法识别输出 → nil（解析失败，按空映射恢复并记日志）")
            expect(KeyRemapper.parseUserKeyMapping("( { HIDKeyboardModifierMappingSrc = 1; } )") == nil,
                   "条目缺 Dst → nil（解析失败）")
        }

        // 加固-3. resetInputState：清瞬时层/OK 物理态/在途定时器（设备移除/睡眠/tap 失效恢复路径）
        expect(MappingEngine.resetSelfCheck(), "MappingEngine resetInputState 自测")

        // M6-1. EnvironmentCheck API 健全性：只断言可调用不崩、返回结构完整，
        //       不断言具体授权状态（取决于运行环境）。
        do {
            func stateTag(_ s: EnvCheckState) -> String {
                switch s {
                case .granted: return "granted"
                case .denied: return "denied"
                case .unknown: return "unknown"
                }
            }
            let ax = EnvironmentCheck.accessibility()
            expect(ax.guideURL?.scheme == "x-apple.systempreferences",
                   "EnvCheck 辅助功能可调用+设置面板URL", stateTag(ax.state))
            let im = EnvironmentCheck.inputMonitoring()
            expect(im.guideURL?.scheme == "x-apple.systempreferences",
                   "EnvCheck 输入监控可调用+设置面板URL", stateTag(im.state))
            let bh = EnvironmentCheck.blackHole()
            expect(bh.guideURL?.host == "existential.audio",
                   "EnvCheck BlackHole 可调用+官方下载URL", stateTag(bh.state))
            let rc = EnvironmentCheck.remoteConnected()
            expect((rc.state == .granted || rc.state == .denied)
                   && rc.guideURL?.scheme == "x-apple.systempreferences",
                   "EnvCheck 遥控器枚举可调用+蓝牙面板URL", stateTag(rc.state))
        }

        // 稳定性-1. HealthMonitor.computeOverall 四源汇聚纯逻辑
        do {
            var s = HealthSources(keysEnabled: true, bleConnected: true, tapAlive: true,
                                  mappingInstalled: true, accessibilityGranted: true,
                                  inputMonitoringGranted: true)
            expect(HealthMonitor.computeOverall(s) == .healthy, "健康态：四源全好 → healthy")
            s.bleConnected = false
            if case .degraded(let why) = HealthMonitor.computeOverall(s) {
                expect(why.count == 1 && why[0].contains("蓝牙"), "健康态：BLE 断开 → degraded(蓝牙)", "\(why)")
            } else { expect(false, "健康态：BLE 断开 → degraded") }
            s.tapAlive = false
            if case .broken(let why) = HealthMonitor.computeOverall(s) {
                expect(why.contains(where: { $0.contains("CGEventTap") }), "健康态：tap 失效 → broken", "\(why)")
            } else { expect(false, "健康态：tap 失效 → broken") }
            s = HealthSources(keysEnabled: false, bleConnected: true, tapAlive: false,
                              mappingInstalled: false, accessibilityGranted: true,
                              inputMonitoringGranted: true)
            expect(HealthMonitor.computeOverall(s) == .healthy, "健康态：未启用按键模式时 tap/映射不参与判定")
            s.accessibilityGranted = false
            if case .broken = HealthMonitor.computeOverall(s) {
                expect(true, "健康态：辅助功能撤权 → broken")
            } else { expect(false, "健康态：辅助功能撤权 → broken") }
            s = HealthSources(keysEnabled: true, bleConnected: true, tapAlive: true,
                              mappingInstalled: false, accessibilityGranted: true,
                              inputMonitoringGranted: true)
            if case .degraded(let why) = HealthMonitor.computeOverall(s) {
                expect(why.contains(where: { $0.contains("中转映射") }), "健康态：映射缺失 → degraded(映射)", "\(why)")
            } else { expect(false, "健康态：映射缺失 → degraded") }
        }

        // 稳定性-2. 单实例锁：路径生成 + flock 独占互斥（同进程二次 open 也拿不到）
        do {
            expect(HealthMonitor.lockFilePath().hasSuffix("MiRemote/miremote.lock"),
                   "锁文件路径生成", HealthMonitor.lockFilePath())
            let tmp = NSTemporaryDirectory() + "miremote-selftest-\(getpid()).lock"
            defer { unlink(tmp) }
            let fd1 = HealthMonitor.tryLock(path: tmp)
            expect(fd1 != nil, "首次加锁成功")
            expect(HealthMonitor.tryLock(path: tmp) == nil, "锁被持有时二次加锁失败（独占非阻塞）")
            if let fd1 { flock(fd1, LOCK_UN); close(fd1) }
            let fd2 = HealthMonitor.tryLock(path: tmp)
            expect(fd2 != nil, "释放后可重新加锁")
            if let fd2 { flock(fd2, LOCK_UN); close(fd2) }
        }

        // 稳定性-3. --login-item 参数解析三态 + 非法值
        do {
            expect(LoginItemCommand(rawValue: "on") == .on
                   && LoginItemCommand(rawValue: "off") == .off
                   && LoginItemCommand(rawValue: "status") == .status, "--login-item 三态解析")
            expect(LoginItemCommand(rawValue: "enable") == nil
                   && LoginItemCommand(rawValue: "") == nil, "--login-item 非法值拒绝")
        }

        // 稳定性-4. RepairReport 结构与文案纯逻辑（needsUser/exitCode/lines）
        do {
            let allOK = RepairReport(items: [
                RepairItem(name: "甲", status: .ok, message: "已就绪", guideURL: nil),
                RepairItem(name: "乙", status: .repaired, message: "已清理", guideURL: nil),
                RepairItem(name: "丙", status: .info, message: "仅提示", guideURL: nil),
            ])
            expect(!allOK.needsUser && allOK.exitCode == 0, "RepairReport 全好/已修/提示 → 退出码 0")
            let bad = RepairReport(items: [
                RepairItem(name: "权限", status: .needsUser, message: "去系统设置勾选",
                           guideURL: URL(string: "x-apple.systempreferences:com.apple.preference.security")),
            ])
            expect(bad.needsUser && bad.exitCode == 1, "RepairReport 有需处理项 → 退出码 1")
            let lines = bad.lines()
            expect(lines.count == 1 && lines[0].contains("[需处理]") && lines[0].contains("权限")
                   && lines[0].contains("去系统设置勾选") && lines[0].contains("x-apple.systempreferences"),
                   "RepairReport 文案含标记/名称/指引/URL", lines.first ?? "")
            expect(allOK.lines().allSatisfy { !$0.contains("http") },
                   "非需处理项不拼接 guideURL")
        }
        // M5-1. ConfigStore 写回往返（临时文件；pretty/sortedKeys 编码稳定）
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("miremote-selftest-\(ProcessInfo.processInfo.processIdentifier).json")
            defer { try? FileManager.default.removeItem(at: tmp) }
            var cfg = MappingConfig()
            cfg.settings.holdMs = 420
            cfg.settings.doubleMs = 250
            cfg.profiles["global"] = [
                "ok": KeyBinding(tap: .keyStroke(key: "return", mods: ["right_option"]),
                                 hold: .layerMomentary(1),
                                 gesture: ["up": .system("mission_control")],
                                 layers: ["2": .keyStroke(key: "1", mods: [])]),
            ]
            cfg.profiles["com.example.app"] = ["tv": KeyBinding(tap: .shell("true"))]
            expect(ConfigStore.save(cfg, to: tmp), "ConfigStore 写入成功")
            let back = ConfigStore.load(from: tmp)
            expect(back?.settings.holdMs == 420 && back?.settings.doubleMs == 250
                   && back?.profiles["global"]?["ok"]?.tap == .keyStroke(key: "return", mods: ["right_option"])
                   && back?.profiles["global"]?["ok"]?.layers?["2"] == .keyStroke(key: "1", mods: [])
                   && back?.profiles["com.example.app"]?["tv"]?.tap == .shell("true"),
                   "ConfigStore 写回往返")
            // 损坏文件 → load 返回 nil（UI 体检页「恢复默认配置」路径）
            try? Data("not json".utf8).write(to: tmp)
            expect(ConfigStore.load(from: tmp) == nil, "ConfigStore 损坏文件返回 nil")
        }

        // M5-2. Action 人类可读摘要（ActionPicker 关闭态 / 预设预览共用的纯函数）
        expect(ActionSummary.selfCheck(), "ActionSummary 摘要渲染")

        // M5-3. RemoteDiagram 几何命中测试（13 键 + 空白区）
        expect(RemoteDiagramGeometry.selfCheck(), "RemoteDiagram 命中测试")

        // M5-4. 键展示元数据齐备（13 键中文名/usage/徽标）
        expect(KeyDisplay.selfCheck(), "KeyDisplay 13 键元数据齐备")

        // M5-5. 录制键名反查表：常用键可反查、别名不夺位
        expect(KeyNameLookup.canonical[36] == "return"
               && KeyNameLookup.canonical[53] == "escape"
               && KeyNameLookup.canonical[51] == "delete"
               && KeyNameLookup.canonical[126] == "up_arrow",
               "KeyNameLookup 反查表规范名")
        // 修饰键设备位 → 名称
        expect(KeyNameLookup.mods(fromRawFlags: 0x08 | 0x02).sorted() == ["left_cmd", "left_shift"]
               && KeyNameLookup.mods(fromRawFlags: 0x40) == ["right_option"],
               "KeyNameLookup 左右修饰位解析")
        print(failures == 0 ? "SELF-TEST PASS" : "SELF-TEST FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
