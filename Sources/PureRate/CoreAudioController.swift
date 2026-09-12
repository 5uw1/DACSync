import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// Thin wrapper around the CoreAudio HAL for listing output devices and
/// changing a device's nominal sample rate so the OS doesn't have to
/// resample audio before handing it to the DAC.
final class CoreAudioController {

    enum ControllerError: Error, LocalizedError {
        case propertyReadFailed(String, OSStatus)
        case propertyWriteFailed(String, OSStatus)
        case noOutputStreams

        var errorDescription: String? {
            switch self {
            case .propertyReadFailed(let prop, let status):
                return "Failed to read \(prop) (OSStatus \(status))"
            case .propertyWriteFailed(let prop, let status):
                return "Failed to write \(prop) (OSStatus \(status))"
            case .noOutputStreams:
                return "Device has no output streams"
            }
        }
    }

    // MARK: Device discovery

    func defaultOutputDevice() throws -> AudioOutputDevice {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioHardwarePropertyDefaultOutputDevice", status)
        }
        return AudioOutputDevice(id: deviceID, name: try name(of: deviceID))
    }

    func outputDevices() throws -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioHardwarePropertyDevices size", status)
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioHardwarePropertyDevices", status)
        }

        return deviceIDs.compactMap { id in
            guard hasOutputStreams(id), let deviceName = try? name(of: id) else { return nil }
            return AudioOutputDevice(id: id, name: deviceName)
        }
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private func name(of id: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfName: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfName) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfName else {
            throw ControllerError.propertyReadFailed("kAudioObjectPropertyName", status)
        }
        return cfName as String
    }

    // MARK: Sample rate

    func nominalSampleRate(of id: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioDevicePropertyNominalSampleRate", status)
        }
        return rate
    }

    func availableSampleRates(of id: AudioDeviceID) throws -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioDevicePropertyAvailableNominalSampleRates size", status)
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioDevicePropertyAvailableNominalSampleRates", status)
        }
        // Ranges are usually degenerate (min == max) for one discrete rate each.
        var rates = Set<Double>()
        for range in ranges {
            rates.insert(range.mMinimum)
            rates.insert(range.mMaximum)
        }
        return rates.sorted()
    }

    /// Sets the device's nominal sample rate to the exact source rate if the
    /// device supports it, otherwise the closest supported rate — preferring
    /// a rate in the same 44.1kHz or 48kHz family as the source to avoid an
    /// extra asynchronous rate conversion.
    @discardableResult
    func matchSampleRate(of id: AudioDeviceID, toSourceRate sourceRate: Double) throws -> Double {
        let available = try availableSampleRates(of: id)
        guard !available.isEmpty else { throw ControllerError.noOutputStreams }

        let target = closestRate(to: sourceRate, in: available)
        let current = try nominalSampleRate(of: id)
        guard abs(current - target) > 1 else { return current }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = target
        let size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, size, &rate)
        guard status == noErr else {
            throw ControllerError.propertyWriteFailed("kAudioDevicePropertyNominalSampleRate", status)
        }
        return target
    }

    private func closestRate(to sourceRate: Double, in available: [Double]) -> Double {
        if let exact = available.first(where: { abs($0 - sourceRate) < 1 }) {
            return exact
        }
        func family(_ rate: Double) -> Double { rate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000 }
        let sourceFamily = family(sourceRate)
        let sameFamily = available.filter { family($0) == sourceFamily && $0 >= sourceRate }
        if let nearestAbove = sameFamily.min() {
            return nearestAbove
        }
        return available.min(by: { abs($0 - sourceRate) < abs($1 - sourceRate) }) ?? sourceRate
    }

    // MARK: Hog mode (exclusive access)

    /// Taking "hog mode" stops other processes/the system mixer from opening
    /// the device concurrently, which is what lets a sample-rate change here
    /// stick instead of being fought by CoreAudio's shared mix engine.
    func setHogMode(of id: AudioDeviceID, owned: Bool) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = owned ? pid_t(ProcessInfo.processInfo.processIdentifier) : pid_t(-1)
        let size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, size, &pid)
        guard status == noErr else {
            throw ControllerError.propertyWriteFailed("kAudioDevicePropertyHogMode", status)
        }
    }
}
