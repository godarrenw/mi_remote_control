import Foundation

/// 标准 IMA/DVI ADPCM 解码器（16 kHz 单声道 16-bit，4:1）。
/// 每字节高 nibble 在前、低 nibble 在后，各解一个样本。
final class ADPCMDecoder {
    // 89 级步长表
    private static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
        3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]

    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8]

    private var predictor: Int32 = 0
    private var stepIndex: Int = 0

    /// 用同步帧的 predictor/stepIndex 重置解码器状态。
    func reset(predictor: Int16, stepIndex: Int) {
        self.predictor = Int32(predictor)
        self.stepIndex = min(max(stepIndex, 0), 88)
    }

    /// 解一批 ADPCM 字节，返回 16-bit 样本（每字节 2 个）。
    func decode(_ data: Data) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(decodeNibble(byte >> 4))    // 高 nibble 在前
            out.append(decodeNibble(byte & 0x0F))  // 低 nibble 在后
        }
        return out
    }

    private func decodeNibble(_ nibble: UInt8) -> Int16 {
        let step = ADPCMDecoder.stepTable[stepIndex]
        let sign = nibble & 0x08
        let mag = Int32(nibble & 0x07)

        // diff = step * (mag + 0.5) 的整数展开
        var diff = step >> 3
        if mag & 4 != 0 { diff += step }
        if mag & 2 != 0 { diff += step >> 1 }
        if mag & 1 != 0 { diff += step >> 2 }

        predictor += (sign != 0) ? -diff : diff
        predictor = min(max(predictor, -32768), 32767)

        stepIndex += ADPCMDecoder.indexTable[Int(nibble & 0x07)]
        stepIndex = min(max(stepIndex, 0), 88)

        return Int16(predictor)
    }
}

/// 按帧长把 BLE 分包重组为完整帧。
struct FrameAccumulator {
    private let frameSize: Int
    private var buffer = Data()

    init(frameSize: Int = 120) {
        self.frameSize = frameSize
    }

    /// 追加一段分包数据，返回已凑满的完整帧（可能 0 个或多个）。
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames = [Data]()
        while buffer.count >= frameSize {
            frames.append(buffer.prefix(frameSize))
            buffer.removeFirst(frameSize)
        }
        return frames
    }

    /// 丢弃缓冲中尚未凑满的残余半帧（同步帧到达 / 帧格式重探测时对齐帧边界）。
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

/// PCM 后处理：[1,2,1]/4 三点平滑（跨批次保留末两样本）+ 线性增益。
final class PCMPostprocessor {
    private var gain: Double
    private var prev1: Int16?  // 上一样本 x[n-1]
    private var prev2: Int16?  // 上上样本 x[n-2]

    /// - Parameter gainDB: 增益（分贝），默认 0（不放大）。
    init(gainDB: Double = 0) {
        self.gain = pow(10.0, gainDB / 20.0)
    }

    func setGain(dB: Double) {
        self.gain = pow(10.0, dB / 20.0)
    }

    /// 清空跨批平滑历史（新语音会话开始 / 同步帧重置时调用，避免用上段的尾样本污染新流）。
    func reset() {
        prev1 = nil
        prev2 = nil
    }

    /// 处理一批样本。三点平滑窗口跨批次连续。
    func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        var out = [Int16]()
        out.reserveCapacity(samples.count)
        for i in 0..<samples.count {
            let x0 = prev2
            let x1 = prev1 ?? samples[i]
            let x2 = samples[i]
            // 首样本无历史时退化为直通
            let smoothed: Int32
            if let a = x0 {
                smoothed = (Int32(a) + 2 * Int32(x1) + Int32(x2)) / 4
            } else {
                smoothed = Int32(x2)
            }
            let scaled = Double(smoothed) * gain
            let clamped = min(max(scaled, -32768), 32767)
            out.append(Int16(clamped))
            prev2 = prev1
            prev1 = samples[i]
        }
        return out
    }
}
