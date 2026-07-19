import Foundation
import CoreAudio

/// 语音会话期间把系统默认输入设备切到 BlackHole，结束后还原。
/// 这样跟随系统默认麦克风的应用（豆包输入法等）无需任何手动设置。
enum DefaultInput {

    private static var savedDevice: AudioDeviceID?
    /// 正常会话在 ATVV 队列操作；退出时还可能与已开始执行的延迟恢复 work 交错。
    /// 锁住 engage/restore 的完整读改写，保证重复恢复幂等且无静态变量数据竞争。
    private static let stateLock = NSLock()

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func currentDefault() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return st == noErr && dev != 0 ? dev : nil
    }

    static func setDefault(_ dev: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var d = dev
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
    }

    /// 按名字前缀找有输入流的设备
    static func findInputDevice(named prefix: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var devs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devs) == noErr else { return nil }

        for dev in devs {
            // 有输入流？
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioDevicePropertyScopeInput,
                                                        mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            // 名字匹配
            var nameAddr = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, &name) == noErr,
                  let cf = name?.takeRetainedValue() else { continue }
            if (cf as String).hasPrefix(prefix) { return dev }
        }
        return nil
    }

    /// 语音开始：默认输入切到 deviceName，记住原设备。已切过则幂等。
    static func engage(deviceName: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let target = findInputDevice(named: deviceName) else { return false }
        let cur = currentDefault()
        if cur == target { return true }
        guard setDefault(target) else { return false }
        if savedDevice == nil { savedDevice = cur }
        return true
    }

    /// 语音结束：还原原默认输入。
    static func restore() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let dev = savedDevice { _ = setDefault(dev) }
        savedDevice = nil
    }
}
