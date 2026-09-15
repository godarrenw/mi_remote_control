import Foundation
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
    private var audioQueue: AudioQueueRef?
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
            // 若上一次 stop 的后台排空尚未真正停机，直接复用仍在运行的播放队列。
            if audioQueue != nil {
                isRunning = true
                NSLog("[AudioBridge] 复用运行中的播放队列（取消上一次停机）")
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
                    disposeQueue()
                }
            }
        }
    }

    // MARK: 固定设备的播放队列

    deinit { disposeQueue() }

    private func disposeQueue() {
        if let queue = audioQueue {
            // 同步停止回调，随后才能释放回调使用的 ring。
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
    }

    private func start() throws {
        // AVAudioEngine 的 I/O 节点会跟随默认设备重配置，直接修改其底层 AUHAL
        // 无法保持显式输出绑定。AudioQueue 直接绑定设备 UID，与默认输入切换独立。
        var format = AudioStreamBasicDescription(
            mSampleRate: sourceSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var created: AudioQueueRef?
        try check(AudioQueueNewOutput(&format, { context, queue, buffer in
            guard let context else { return }
            let ring = Unmanaged<RingBuffer>.fromOpaque(context).takeUnretainedValue()
            let count = Int(buffer.pointee.mAudioDataBytesCapacity) / MemoryLayout<Float>.size
            ring.read(into: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count)
            buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }, Unmanaged.passUnretained(ring).toOpaque(), nil, nil, 0, &created), "创建播放队列")
        guard let queue = created else {
            throw NSError(domain: "AudioBridge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "未创建播放队列"])
        }
        do {
            if let name = deviceName {
                if let deviceID = CoreAudioDevices.findOutputDevice(namePrefix: name) {
                    var address = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var uid: CFString?
                    var size = UInt32(MemoryLayout<CFString?>.size)
                    try withUnsafeMutablePointer(to: &uid) { pointer in
                        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer), "读取输出设备 UID")
                        try check(AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice,
                                                        pointer, size), "绑定输出设备")
                    }
                } else {
                    NSLog("[AudioBridge] 未找到输出设备 %@，回退系统默认输出", name)
                }
            }
            // 3 个 20ms 单声道缓冲；AudioQueue 负责向设备采样率/通道格式转换。
            let byteCount = UInt32(sourceSampleRate * 0.02) * UInt32(MemoryLayout<Float>.size)
            for _ in 0..<3 {
                var allocated: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(queue, byteCount, &allocated), "分配播放缓冲")
                guard let buffer = allocated else {
                    throw NSError(domain: "AudioBridge", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "未分配播放缓冲"])
                }
                memset(buffer.pointee.mAudioData, 0, Int(byteCount))
                buffer.pointee.mAudioDataByteSize = byteCount
                try check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), "提交播放缓冲")
            }
            try check(AudioQueueStart(queue, nil), "启动播放")
            audioQueue = queue
        } catch {
            AudioQueueDispose(queue, true)
            throw error
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "AudioBridge", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(operation)失败 (\(status))"])
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
