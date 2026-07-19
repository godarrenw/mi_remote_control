import Foundation
import CoreBluetooth

/// ATVV（Android TV Voice）私有 GATT 服务的 CoreBluetooth 桥。
///
/// 负责连接遥控器的 ATVV 服务、执行握手状态机、把音频帧切好后经 delegate 上报。
/// 与系统的 HID 连接共存于同一条 BLE 链路，互不干扰。
///
/// 线程模型：CBCentralManager 使用专用串行 queue，所有 delegate 回调直接在该 queue 上
/// 触发（由 main 侧负责后续调度）。
///
/// 并发标注：所有可变状态只在专用串行 `queue` 上读写（CBCentralManager 的回调也落在该
/// queue），因此对外满足 `Sendable` 但需 `@unchecked` —— 由串行 queue 而非编译器保证隔离。
final class ATVVBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    weak var delegate: ATVVBridgeDelegate?

    // MARK: - UUID（来自 Contracts，不得改动）

    private let serviceUUID = CBUUID(string: ATVVUUID.service)
    private let txUUID      = CBUUID(string: ATVVUUID.tx)
    private let audioUUID   = CBUUID(string: ATVVUUID.audio)
    private let controlUUID = CBUUID(string: ATVVUUID.control)

    // MARK: - 电池服务（M5 UI 电量显示；与 ATVV 语音状态机完全独立）

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID   = CBUUID(string: "2A19")
    /// 最近读到的电量（0-100）。ATVV 队列写，读方通过 onBatteryLevel 回调获取。
    private(set) var batteryPercent: Int?
    /// 电量更新回调（在 ATVV 队列上触发，消费方自行切主线程）。
    var onBatteryLevel: ((Int) -> Void)?
    private var batteryChar: CBCharacteristic?
    private var batteryRefreshWork: DispatchWorkItem?

    /// Battery Level 是一个无符号百分比；坏值钳到 100，空包忽略。
    static func parseBatteryLevel(_ data: Data) -> Int? {
        data.first.map { Int(min($0, 100)) }
    }

    // MARK: - 命令字节

    private static let getCaps: [UInt8] = [0x0A, 0x01, 0x00, 0x00, 0x03, 0x03]

    // MARK: - 运行时状态

    private let queue = DispatchQueue(label: "com.miremote.atvv", qos: .userInitiated)
    private var central: CBCentralManager!

    /// 用户意图：start() 置真、stop() 置假。断线后据此决定是否自动重连。
    private var shouldRun = false

    /// 代际隔离：每次连接递增，旧代的回调/延迟操作一律丢弃。
    private var generation = 0

    /// 重连退避序列（秒）：1 → 2 → 5，其后钳在 5。
    private static let backoff: [Double] = [1, 2, 5]
    private var reconnectAttempt = 0

    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var audioChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?

    /// 订阅完成计数：audio + control 都就绪后发 GET_CAPS。
    private var audioSubscribed = false
    private var controlSubscribed = false
    private var capsRequested = false

    // MARK: - 握手协商结果

    private var protocolVersion: UInt16 = 0        // 能力帧字节1-2 BE
    private var codecMask: UInt16 = 0              // 能力帧字节3-4 BE
    private var selectedCodec: UInt8 = 0
    private var capsFrameLen = 120                 // 能力帧字节5-6 BE，0 则默认 120
    private var sessionID: UInt16 = 0

    /// 能力帧是否已解析成功（用于 S8：0x08 早于 0x0B 时暂存开麦请求）。
    private var capsReady = false
    /// caps 未就绪时到达的开麦请求，caps 完成后补发。
    private var micOpenPending = false

    private var streaming = false

    // MARK: - 音频切帧

    private var accumulator = FrameAccumulator(frameSize: 120)
    /// 收到 0x0A 同步帧后挂起，随下一批音频的第一帧下发，之后清空。
    private var pendingSync: (predictor: Int16, stepIndex: Int)?
    /// 当前会话是否检测到 6 字节帧头（帧长 == 能力帧长+6）。
    private var headerMode = false
    /// 是否已对本会话的音频帧长做过一次头部探测。
    private var frameFormatProbed = false
    /// 帧格式探测缓冲：对累计流探测而非仅首包，容忍分包/粘包/空包。
    private var probeBuffer = Data()
    /// 帧长错乱后置真：丢弃后续音频，直到下一个 0x0A 同步帧重新对齐才恢复。
    private var waitingForResync = false

    // MARK: - 断连原因暂存（C7：避免手动 + didDisconnect 双重回调）

    /// 主动断连前把原因暂存于此，统一由 didDisconnectPeripheral 发一次事件。
    private var pendingDisconnectReason: String?

    // MARK: - 生命周期

    init(delegate: ATVVBridgeDelegate?) {
        self.delegate = delegate
        super.init()
        // 在专用 queue 上创建 central，delegate 回调都落到该 queue。
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// 开始扫描/连接。可在 central 尚未 poweredOn 时调用——就绪后自动接续。
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.log("START requested")
            if self.central.state == .poweredOn {
                self.attemptConnect()
            } else {
                self.log("waiting for Bluetooth poweredOn (state=\(self.central.state.rawValue))")
            }
        }
    }

    /// 停止并断开。
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.log("STOP requested")
            self.teardownConnection(disconnect: true)
        }
    }

    // MARK: - 连接策略

    private func attemptConnect() {
        guard shouldRun, central.state == .poweredOn else { return }

        // 首选：系统已因 HID 保持连接，直接取回已连接外设（最常见路径）。
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let p = connected.first {
            log("ATVV_FOUND_CONNECTED name=\(p.name ?? "?")")
            connect(to: p)
            return
        }

        // 否则扫描该 service。
        log("ATVV_SCAN_START service=\(serviceUUID.uuidString)")
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    private func connect(to p: CBPeripheral) {
        central.stopScan()
        // 新连接开一代，旧代闭包全部作废。
        generation += 1
        resetSessionState()
        peripheral = p
        p.delegate = self
        log("CONNECTING gen=\(generation)")
        central.connect(p, options: nil)
    }

    private func resetSessionState() {
        batteryRefreshWork?.cancel()
        batteryRefreshWork = nil
        batteryChar = nil
        txChar = nil
        audioChar = nil
        controlChar = nil
        audioSubscribed = false
        controlSubscribed = false
        capsRequested = false
        capsReady = false
        micOpenPending = false
        streaming = false
        pendingSync = nil
        headerMode = false
        frameFormatProbed = false
        probeBuffer.removeAll(keepingCapacity: true)
        waitingForResync = false
        accumulator = FrameAccumulator(frameSize: capsFrameLen)
    }

    /// 标准 Battery Service 支持 notify，但部分固件只在电量跨档时通知。
    /// 首读之外每 60 秒轻量补读一次，也能覆盖首次回调/界面订阅竞态。
    private func scheduleBatteryRefresh() {
        batteryRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun,
                  let peripheral = self.peripheral,
                  let characteristic = self.batteryChar else { return }
            peripheral.readValue(for: characteristic)
            self.scheduleBatteryRefresh()
        }
        batteryRefreshWork = work
        queue.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func teardownConnection(disconnect: Bool) {
        if let p = peripheral {
            // 代际隔离：摘掉旧外设的 delegate，杜绝跨代的 peripheral 级回调回流。
            p.delegate = nil
            if disconnect {
                central.cancelPeripheralConnection(p)
            }
        }
        central.stopScan()
        peripheral = nil
        resetSessionState()
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        let delay = ATVVBridge.backoff[min(reconnectAttempt, ATVVBridge.backoff.count - 1)]
        reconnectAttempt += 1
        let g = generation
        log("RECONNECT scheduled in \(delay)s (attempt \(reconnectAttempt))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // 期间若已发起新连接（generation 变动）或被 stop，放弃本次重连。
            guard self.shouldRun, self.generation == g, self.peripheral == nil else { return }
            self.attemptConnect()
        }
    }

    // MARK: - 代际隔离

    /// 回调入口统一校验：该外设必须是当前代正在跟踪的活动外设。
    ///
    /// 纯 `peripheral === self.peripheral` 身份检查不足以应对同一 CBPeripheral 对象跨代复用，
    /// 因此叠加两道防线：(1) teardown 时摘除旧外设 delegate；(2) 此处要求 peripheral 非 nil
    /// 且身份相等。connect() 每次递增 generation 并把新外设设为唯一活动对象，从而任何旧代
    /// 遗留的、身份不符或在 teardown 后到达的回调都会被此守卫丢弃。
    private func isCurrent(_ p: CBPeripheral) -> Bool {
        return peripheral != nil && p === peripheral
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("BT_POWERED_ON")
            if shouldRun { attemptConnect() }
        case .poweredOff:
            log("BT_POWERED_OFF")
            delegate?.atvvDisconnected(error: "Bluetooth powered off")
            teardownConnection(disconnect: false)
        case .unauthorized:
            log("BT_UNAUTHORIZED")
            delegate?.atvvDisconnected(error: "Bluetooth unauthorized")
        case .unsupported:
            log("BT_UNSUPPORTED")
            delegate?.atvvDisconnected(error: "Bluetooth unsupported")
        default:
            log("BT_STATE=\(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // S6：已在连接/已连接（self.peripheral 非 nil）时忽略新广播，避免重复 connect。
        guard shouldRun, self.peripheral == nil else {
            log("ATVV_DISCOVERED ignored (already connecting/connected)")
            return
        }
        log("ATVV_DISCOVERED name=\(peripheral.name ?? "?") rssi=\(RSSI)")
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // C3：连接成功回调也需代际校验，丢弃旧代/非活动外设的迟到回调。
        guard isCurrent(peripheral) else {
            log("CONNECTED ignored (stale peripheral)")
            return
        }
        reconnectAttempt = 0
        log("CONNECTED name=\(peripheral.name ?? "?")")
        delegate?.atvvConnected(deviceName: peripheral.name ?? "MI RC")
        // 同时发现 ATVV 与标准电池服务；电池纯只读旁路，不参与握手状态机。
        peripheral.discoverServices([serviceUUID, batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // C3：非当前活动外设的失败回调不得清掉正在跟踪的 peripheral。
        guard isCurrent(peripheral) else {
            log("CONNECT_FAILED ignored (stale peripheral)")
            return
        }
        log("CONNECT_FAILED error=\(error?.localizedDescription ?? "nil")")
        self.peripheral?.delegate = nil
        self.peripheral = nil
        resetSessionState()
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // C3：仅处理当前活动外设的断连。
        guard isCurrent(peripheral) else {
            log("DISCONNECTED ignored (stale peripheral)")
            return
        }
        // C7：优先用系统错误，否则用主动断连时暂存的原因；两者都无则 nil。
        let msg = error?.localizedDescription ?? pendingDisconnectReason
        pendingDisconnectReason = nil
        log("DISCONNECTED error=\(msg ?? "nil")")
        delegate?.atvvDisconnected(error: msg)
        peripheral.delegate = nil
        self.peripheral = nil
        resetSessionState()
        scheduleReconnect()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error {
            log("SERVICE_DISCOVERY_ERROR \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            // C7：只暂存原因并 cancel，由 didDisconnectPeripheral 统一发一次断连事件。
            log("ATVV_SERVICE_MISSING")
            pendingDisconnectReason = "ATVV service not found"
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("ATVV_SERVICE_FOUND")
        peripheral.discoverCharacteristics([txUUID, audioUUID, controlUUID], for: service)
        // 电池服务（可选，缺失不影响语音链路）。
        if let batt = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID }) {
            peripheral.discoverCharacteristics([batteryLevelUUID], for: batt)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error {
            log("CHAR_DISCOVERY_ERROR \(error.localizedDescription)")
            return
        }
        // 电池服务分支：读一次 + 订阅 notify 后即返回，绝不进入下方 ATVV 特征齐备校验。
        if service.uuid == batteryServiceUUID {
            if let c = service.characteristics?.first(where: { $0.uuid == batteryLevelUUID }) {
                batteryChar = c
                peripheral.readValue(for: c)
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
                scheduleBatteryRefresh()
                log("BATTERY_CHAR_FOUND")
            }
            return
        }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case txUUID:      txChar = c
            case audioUUID:   audioChar = c
            case controlUUID: controlChar = c
            default: break
            }
        }
        guard let audioChar, let controlChar, txChar != nil else {
            // C7：同上，只暂存原因并 cancel，避免双重断连回调。
            log("CHAR_MISSING tx=\(txChar != nil) audio=\(audioChar != nil) control=\(controlChar != nil)")
            pendingDisconnectReason = "ATVV characteristics incomplete"
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("ATVV_CHARS_FOUND")
        peripheral.setNotifyValue(true, for: audioChar)
        peripheral.setNotifyValue(true, for: controlChar)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error {
            log("NOTIFY_ERROR \(characteristic.uuid) \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == audioUUID { audioSubscribed = characteristic.isNotifying }
        if characteristic.uuid == controlUUID { controlSubscribed = characteristic.isNotifying }

        // audio + control 都订阅完成后发 GET_CAPS 启动握手。
        if audioSubscribed && controlSubscribed && !capsRequested {
            capsRequested = true
            sendGetCaps()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error {
            log("VALUE_ERROR \(characteristic.uuid) \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case controlUUID: handleControl(data)
        case audioUUID:   handleAudio(data)
        case batteryLevelUUID:
            if let pct = Self.parseBatteryLevel(data) {
                batteryPercent = pct
                log("BATTERY \(pct)%")
                onBatteryLevel?(pct)
            }
        default: break
        }
    }

    // MARK: - 握手状态机（严格按 DESIGN.md §1.3 时序）

    private func sendGetCaps() {
        guard let tx = txChar, let p = peripheral else { return }
        log("GET_CAPS")
        p.writeValue(Data(ATVVBridge.getCaps), for: tx, type: .withResponse)
    }

    private func handleControl(_ data: Data) {
        guard let op = data.first else { return }
        let b = [UInt8](data)
        switch op {

        case 0x0B: // 能力帧
            handleCaps(b)

        case 0x08: // 用户按下语音键，请求开麦
            log("MIC_REQUEST (0x08)")
            // S8：能力帧尚未就绪时暂存请求，caps 完成后补发 MIC_OPEN。
            if capsReady {
                sendMicOpen()
            } else {
                micOpenPending = true
                log("MIC_REQUEST deferred (caps not ready)")
            }

        case 0x04: // 流开始
            handleStreamStart(b)

        case 0x0A: // 同步帧
            handleSyncFrame(b)

        case 0x00: // 流结束
            handleStreamStop()

        default:
            log("CTL_UNKNOWN op=\(hex(op))")
        }
    }

    private func handleCaps(_ b: [UInt8]) {
        // S7：能力帧至少需 7 字节（op + 版本2 + codec2 + 帧长2）。不足即协议错误，断开——
        // 不得静默当作"不支持 16kHz"，否则会误导重连逻辑。
        guard b.count >= 7 else {
            log("CAPS_MALFORMED len=\(b.count) (protocol error)")
            pendingDisconnectReason = "malformed caps frame (len=\(b.count))"
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }

        // 字节1-2 版本 BE、3-4 codec 掩码 BE、5-6 帧长 BE（0 则默认 120）。
        protocolVersion = be16(b, 1)
        codecMask = be16(b, 3)
        let frame = be16(b, 5)
        capsFrameLen = frame == 0 ? 120 : Int(frame)
        accumulator = FrameAccumulator(frameSize: capsFrameLen)

        log("CAPS version=\(hex16(protocolVersion)) codecs=\(hex16(codecMask)) frame=\(capsFrameLen)")

        // ponytail: S3 —— 固定选 0x02(16kHz) 且掩码位含义来自实测；不同固件位定义可能不同，
        // 需实机验证。升级路径：把 codec 位→采样率的映射做成表，按协商结果选采样率下发给 sink。
        guard codecMask & 0x02 != 0 else {
            log("CAPS_UNSUPPORTED no 16kHz codec")
            pendingDisconnectReason = "remote does not support 16kHz codec"
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        selectedCodec = 0x02
        capsReady = true
        log("CAPS_OK selectedCodec=0x02, awaiting mic key")

        // S8：若开麦请求早于能力帧到达，此刻补发 MIC_OPEN。
        if micOpenPending {
            micOpenPending = false
            log("MIC_OPEN (deferred, caps now ready)")
            sendMicOpen()
        }
    }

    private func sendMicOpen() {
        guard let tx = txChar, let p = peripheral else { return }
        // 版本 ≥ 0x0100 → 0C 00；否则 0C 00 02。
        let payload: [UInt8] = protocolVersion >= 0x0100 ? [0x0C, 0x00] : [0x0C, 0x00, 0x02]
        log("MIC_OPEN \(hexBytes(payload))")
        p.writeValue(Data(payload), for: tx, type: .withResponse)
    }

    private func handleStreamStart(_ b: [UInt8]) {
        // v1.0 布局：字节1 codec、字节2-3 sessionID BE。容错解析。
        if b.count >= 4 {
            sessionID = be16(b, 2)
        } else {
            sessionID = 0
        }
        streaming = true
        pendingSync = nil
        frameFormatProbed = false
        headerMode = false
        probeBuffer.removeAll(keepingCapacity: true)
        waitingForResync = false
        accumulator = FrameAccumulator(frameSize: capsFrameLen)
        log("AUDIO_START sessionID=\(hex16(sessionID))")
        delegate?.atvvVoiceStarted()
    }

    private func handleSyncFrame(_ b: [UInt8]) {
        // predictor(Int16 BE) 字节1-2、stepIndex 字节3。挂起，随下一帧下发。
        let predictor = Int16(bitPattern: be16(b, 1))
        let step = b.count > 3 ? Int(b[3]) : 0

        // S11：同步帧标志一个干净的帧边界。先丢弃 accumulator/probe 中的残余半帧，
        // 避免把错位的旧字节拼进新帧。
        accumulator.reset()
        probeBuffer.removeAll(keepingCapacity: true)

        // C5：帧长错乱进入 waitingForResync 后，0x0A 是唯一恢复点——重新探测帧格式并恢复接收。
        if waitingForResync {
            waitingForResync = false
            frameFormatProbed = false
            log("RESYNC on 0x0A")
        }

        pendingSync = (predictor: predictor, stepIndex: step)
        log("SYNC predictor=\(predictor) step=\(step)")
    }

    private func handleStreamStop() {
        // 实机发现：MIC_CLOSE 会引来遥控器再回一个 0x00，若不加门控会无限乒乓。
        // 只有"流进行中"的第一个 0x00 才算数，其余静默忽略。
        guard streaming else { return }
        streaming = false
        log("AUDIO_STOP")
        delegate?.atvvVoiceStopped()
        sendMicClose()
    }

    private func sendMicClose() {
        guard let tx = txChar, let p = peripheral else { return }
        // 版本 ≥ 0x0100 → 0D + sessionID 2 字节；否则 0D。
        var payload: [UInt8] = [0x0D]
        if protocolVersion >= 0x0100 {
            payload.append(UInt8(sessionID >> 8))
            payload.append(UInt8(sessionID & 0xFF))
        }
        log("MIC_CLOSE \(hexBytes(payload))")
        p.writeValue(Data(payload), for: tx, type: .withResponse)
    }

    // MARK: - 音频帧

    private func handleAudio(_ data: Data) {
        // C2：0x04 之前 / 0x00 之后到达的音频帧一律丢弃（非流内数据）。
        guard streaming else { return }

        // C5：帧长错乱后进入等待重同步——丢弃所有音频，直到 0x0A 重新对齐。
        if waitingForResync {
            return
        }

        // 空包不消耗探测机会，直接忽略。
        guard !data.isEmpty else { return }

        // 帧头探测（C5）：对累计缓冲探测而非仅首包，容忍分包/粘包。
        if !frameFormatProbed {
            probeBuffer.append(data)
            // 尚未累计到一个能力帧长，继续等更多分包（探测窗口内允许分包）。
            guard probeBuffer.count >= capsFrameLen else { return }

            let plain = capsFrameLen
            let headered = capsFrameLen + 6
            if probeBuffer.count == headered || (probeBuffer.count % headered == 0 && probeBuffer.count % plain != 0) {
                // 含 6 字节帧头版本。
                headerMode = true
                accumulator = FrameAccumulator(frameSize: headered)
                log("AUDIO_HEADER_MODE on-wire frame=\(headered) (payload \(plain))")
            } else if probeBuffer.count % plain == 0 {
                // 裸能力帧版本。
                headerMode = false
                accumulator = FrameAccumulator(frameSize: plain)
                log("AUDIO_PLAIN_MODE frame=\(plain)")
            } else {
                // 长度对不上任何整数倍：不硬切。丢弃缓冲并等待下一个 0x0A 同步帧再恢复。
                log("AUDIO_FRAME_SIZE_MISMATCH got=\(probeBuffer.count) caps=\(plain), discarding + await resync")
                probeBuffer.removeAll(keepingCapacity: true)
                waitingForResync = true
                return
            }

            frameFormatProbed = true
            // 把探测期间累计的数据交给帧累加器切帧。
            let seed = probeBuffer
            probeBuffer.removeAll(keepingCapacity: true)
            emitFrames(accumulator.append(seed))
            return
        }

        emitFrames(accumulator.append(data))
    }

    private func emitFrames(_ frames: [Data]) {
        for raw in frames {
            if headerMode && raw.count == capsFrameLen + 6 {
                emitHeaderedFrame(raw)
            } else {
                emit(raw, sync: takePendingSync())
            }
        }
    }

    /// 剥离 remote-bridge-hub 6 字节帧头 [序列号2B + pad1B + predictor2B + stepIndex1B]，
    /// 其中 predictor/stepIndex 作为该帧 sync。
    // ponytail: S1 —— 6 字节帧头的字段布局（序列号/pad/predictor/step 偏移）来自参考实现推断，
    // 尚未在本型号实机抓包验证。风险：布局不符会导致每帧 sync 错位、音质异常。
    // 升级路径：实机抓一段 headerMode 音频，对齐偏移；必要时把 be16(b,3)/b[5] 的取值做成可配置。
    private func emitHeaderedFrame(_ raw: Data) {
        let b = [UInt8](raw)
        let predictor = Int16(bitPattern: be16(b, 3))
        let step = Int(b[5])
        let payload = raw.subdata(in: (raw.startIndex + 6)..<raw.endIndex)
        // 头部自带 sync 优先；同时消费任何挂起的 0x0A sync 以免陈旧。
        _ = takePendingSync()
        emit(payload, sync: (predictor: predictor, stepIndex: step))
    }

    /// 取出并清空挂起的同步帧（只随第一帧发出一次）。
    private func takePendingSync() -> (predictor: Int16, stepIndex: Int)? {
        defer { pendingSync = nil }
        return pendingSync
    }

    private func emit(_ frame: Data, sync: (predictor: Int16, stepIndex: Int)?) {
        delegate?.atvvAudioFrame(frame, sync: sync)
    }

    // MARK: - 工具

    private func log(_ msg: String) {
        delegate?.atvvLog("ATVV \(msg)")
    }

    /// 从字节数组安全读取大端 16-bit（越界返回 0）。
    private func be16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return (UInt16(b[i]) << 8) | UInt16(b[i + 1])
    }

    private func hex(_ v: UInt8) -> String { String(format: "0x%02X", v) }
    private func hex16(_ v: UInt16) -> String { String(format: "0x%04X", v) }
    private func hexBytes(_ b: [UInt8]) -> String {
        b.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
