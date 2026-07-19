import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// 音频输出桥：把 ATVV 解码出的 16kHz Int16 单声道 PCM 实时播放到指定输出设备
// （典型用法：播到 "BlackHole 2ch"，由豆包输入法把它当麦克风识别成文字）。

// MARK: - CoreAudio 设备工具

private enum CoreAudioDevices {

    /// 枚举系统里所有音频设备的 AudioObjectID。
    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    /// 该设备是否有输出流（>0 个输出通道）。
    static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: Int(dataSize) / MemoryLayout<AudioBufferList>.stride + 1
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr
        else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels: UInt32 = 0
        for buffer in buffers { channels += buffer.mNumberChannels }
        return channels > 0
    }

    /// 设备名（kAudioObjectPropertyName）。
    static func name(of deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cf = name else { return nil }
        return cf as String
    }

    /// 所有带输出流的设备名。
    static func outputDeviceNames() -> [String] {
        allDeviceIDs()
            .filter { hasOutputStreams($0) }
            .compactMap { name(of: $0) }
    }

    /// 按名字前缀匹配第一个有输出流的设备。
    static func findOutputDevice(namePrefix: String) -> AudioObjectID? {
        for id in allDeviceIDs() where hasOutputStreams(id) {
            if let n = name(of: id), n.hasPrefix(namePrefix) {
                return id
            }
        }
        return nil
    }
}

// MARK: - 线程安全环形缓冲（单生产者/单消费者，Float 样本）

// C1：被音频 render 回调（@Sendable 闭包）捕获，内部所有可变状态由 NSLock 保护，
// 故标注 @unchecked Sendable —— 由锁而非编译器保证并发安全。
private final class RingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var fillCount = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// 写入样本，缓冲满则丢弃最旧的（保证实时性，宁可丢老数据不阻塞）。
    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for s in samples {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
            if fillCount == capacity {
                // 满了：覆盖，读指针跟进
                readIndex = (readIndex + 1) % capacity
            } else {
                fillCount += 1
            }
        }
    }

    /// 读取 count 个样本到 dst；不足部分补零（欠载不崩溃）。返回实际读到的有效样本数。
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let available = min(count, fillCount)
        for i in 0..<available {
            dst[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        fillCount -= available
        if available < count {
            for i in available..<count { dst[i] = 0 }
        }
        return available
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return fillCount
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        fillCount = 0
    }
}

// MARK: - AudioBridge

/// 把 16kHz Int16 单声道 PCM 实时播放到指定输出设备。
///
/// C1：start/stop 的状态迁移在 @Sendable 闭包里捕获 self，可变状态统一由串行 stateQueue
/// 串起来（render 回调只碰 ring），因此标注 @unchecked Sendable —— 由 stateQueue 保证隔离。
final class AudioBridge: PCMSink, @unchecked Sendable {

    private let deviceName: String?
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: RingBuffer
    private var sourceSampleRate: Double = 16000
    private var isRunning = false

    // C4/S12：所有 started/stopped 状态迁移都排到这条串行 queue，化解二者竞态；
    // 排空+停引擎的阻塞工作再甩到 workQueue，绝不阻塞调用线程。
    private let stateQueue = DispatchQueue(label: "com.miremote.audiobridge.state")
    private let workQueue = DispatchQueue(label: "com.miremote.audiobridge.work", qos: .userInitiated)
    /// 每次状态迁移自增；停机的后台排空完成后据此判断期间是否又来了新的 start（来了则取消停机）。
    private var generation = 0

    /// - Parameter deviceName: 目标输出设备名前缀（如 "BlackHole 2ch"）；nil = 系统默认输出。
    init(deviceName: String?) {
        self.deviceName = deviceName
        // 几秒容量（按 16k 源速率算，实际以 float 存，容量给足）：4 秒
        self.ring = RingBuffer(capacity: 16000 * 4)
    }

    // MARK: PCMSink

    func streamStarted(sampleRate: Double) {
        stateQueue.async { [self] in
            // S12：新的 start 使任何在途的停机失效（下方 stopped 的后台任务会据 generation 放弃）。
            generation += 1
            guard !isRunning else { return }
            sourceSampleRate = sampleRate
            ring.clear()
            // 若上一次 stop 的后台排空尚未真正停机，引擎仍在运行——直接复用，不重复 attach。
            if engine.isRunning, sourceNode != nil {
                isRunning = true
                NSLog("[AudioBridge] 复用运行中的引擎（取消上一次停机）")
                return
            }
            do {
                try start()
                isRunning = true
            } catch {
                NSLog("[AudioBridge] 启动失败: \(error)")
            }
        }
    }

    func write(_ samples: [Int16]) {
        // Int16 → Float [-1, 1]
        var floats = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            floats[i] = Float(samples[i]) / 32768.0
        }
        ring.write(floats)
    }

    func streamStopped() {
        // C4：调用线程只做一次非阻塞派发；排空+停引擎全部在后台执行。
        stateQueue.async { [self] in
            guard isRunning else { return }
            isRunning = false
            generation += 1
            let gen = generation

            workQueue.async { [self] in
                // 缓冲已有数据才需排空 + 尾巴；已空则直接停机，不做无谓 sleep。
                if ring.count > 0 {
                    let deadline = Date().addingTimeInterval(2.0)
                    while ring.count > 0 && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    Thread.sleep(forTimeInterval: 0.2) // 200ms 尾巴，防截尾
                }
                // 回到状态 queue 真正停机：期间若来了新的 start（generation 变了），取消本次停机。
                stateQueue.async { [self] in
                    guard gen == generation else {
                        NSLog("[AudioBridge] 停机被新的 start 取消")
                        return
                    }
                    engine.stop()
                    if let node = sourceNode {
                        engine.detach(node)
                        sourceNode = nil
                    }
                }
            }
        }
    }

    // MARK: 引擎搭建

    private func start() throws {
        // S10：先绑定目标输出设备，再读取输出格式——绑定会改变 outputNode 的当前设备，
        // 其采样率随之变化，必须在绑定之后读取才拿到目标设备的真实采样率。
        if let name = deviceName {
            if let deviceID = CoreAudioDevices.findOutputDevice(namePrefix: name) {
                try bindOutputDevice(deviceID)
            } else {
                NSLog("[AudioBridge] 未找到输出设备 \"\(name)\"，回退系统默认输出")
            }
        }

        let output = engine.outputNode
        let outputFormat = output.outputFormat(forBus: 0)
        let outputSampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48000

        // 源节点声明为源采样率（16k）单声道 float；engine 自动把 16k→输出设备采样率做上采样。
        // ponytail: 让 AVAudioEngine 内部转换器处理重采样，比手写线性插值简单可靠。
        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioBridge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建源格式"])
        }

        let ringRef = ring
        let node = AVAudioSourceNode(format: srcFormat) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            // 单声道非交错：只有一个 buffer
            if let mData = abl[0].mData {
                let ptr = mData.assumingMemoryBound(to: Float.self)
                ringRef.read(into: ptr, count: n)
            }
            return noErr
        }
        self.sourceNode = node
        engine.attach(node)

        // 连接到主混音器，用输出设备的采样率格式（engine 会在 source(16k)→mixer 之间自动转换）。
        let connectFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        )
        engine.connect(node, to: engine.mainMixerNode, format: connectFormat)

        // S9：引擎启动失败时回滚已 attach 的节点，避免残留半初始化状态污染下次 start。
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            sourceNode = nil
            throw error
        }
    }

    /// 把 engine.outputNode 底层的 AUHAL 绑定到指定 CoreAudio 设备。
    private func bindOutputDevice(_ deviceID: AudioObjectID) throws {
        let audioUnit = engine.outputNode.audioUnit
        guard let au = audioUnit else {
            throw NSError(domain: "AudioBridge", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "outputNode 无 audioUnit"])
        }
        var dev = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: "AudioBridge", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "绑定输出设备失败 (\(status))"])
        }
    }

    // MARK: 静态枚举

    /// 枚举所有输出设备名（给 CLI --list-audio-devices 用）。
    static func listOutputDevices() -> [String] {
        CoreAudioDevices.outputDeviceNames()
    }
}

// MARK: - WAVSink（调试用）

/// 把整段流写成 16-bit 单声道 WAV 文件（streamStopped 时落盘）。
final class WAVSink: PCMSink {
    private let url: URL
    private var sampleRate: Double = 16000
    private var samples: [Int16] = []
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func streamStarted(sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = sampleRate
        samples.removeAll(keepingCapacity: true)
    }

    func write(_ samples: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        self.samples.append(contentsOf: samples)
    }

    func streamStopped() {
        lock.lock()
        let snapshot = samples
        let sr = sampleRate
        lock.unlock()
        do {
            try Self.writeWAV(samples: snapshot, sampleRate: sr, to: url)
        } catch {
            NSLog("[WAVSink] 写文件失败: \(error)")
        }
    }

    /// 手写 44 字节 WAV 头 + PCM 数据。
    private static func writeWAV(samples: [Int16], sampleRate: Double, to url: URL) throws {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let chunkSize = 36 + dataSize

        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(chunkSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))                    // fmt chunk 大小
        appendLE(UInt16(1))                     // PCM
        appendLE(channels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        appendLE(dataSize)
        for s in samples { appendLE(s) }

        try data.write(to: url)
    }
}

// MARK: - TeeSink（广播）

/// 把 PCM 事件广播到多个 sink。
final class TeeSink: PCMSink {
    private let sinks: [PCMSink]

    init(_ sinks: [PCMSink]) {
        self.sinks = sinks
    }

    func streamStarted(sampleRate: Double) { sinks.forEach { $0.streamStarted(sampleRate: sampleRate) } }
    func write(_ samples: [Int16]) { sinks.forEach { $0.write(samples) } }
    func streamStopped() { sinks.forEach { $0.streamStopped() } }
}
