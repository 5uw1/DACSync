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
        case hogModeNotSupported

        var errorDescription: String? {
            switch self {
            case .propertyReadFailed(let prop, let status):
                return "Failed to read \(prop) (OSStatus \(status))"
            case .propertyWriteFailed(let prop, let status):
                return "Failed to write \(prop) (OSStatus \(status))"
            case .noOutputStreams:
                return "Device has no output streams"
            case .hogModeNotSupported:
                return "This device doesn't hold exclusive access (common for built-in speakers — try an external USB DAC)"
            }
        }
    }

    // MARK: Device discovery

    /// Whether `id` still refers to a live device. Discovered the hard way,
    /// verified against a real external DAC (a FiiO K13 R2R): changing a
    /// stream's *physical* format (bit depth) — unlike a plain nominal
    /// sample rate change — can make CoreAudio re-enumerate the device
    /// under a brand new AudioDeviceID. Engaging or releasing Hog Mode was
    /// separately observed doing the same thing on that hardware (likely
    /// the DAC's USB interface briefly resetting for an internal
    /// relay/clock reconfiguration) — either way, a previously cached ID
    /// can silently go stale.
    func deviceExists(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    /// Invokes `handler` (on the main queue) whenever the system's set of
    /// audio devices changes — added/removed/re-enumerated.
    func startWatchingDeviceListChanges(_ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            handler()
        }
    }

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

    // MARK: Bit depth (per-stream physical format)

    /// A DAC's *nominal sample rate* (above) is a device-wide property, but
    /// bit depth lives on each output `AudioStreamID` as part of its
    /// "physical format" — the actual hardware wire format, as opposed to
    /// the Float32 format CoreAudio's shared mixer always uses internally.
    /// Many USB DACs expose the same sample rate at more than one bit depth
    /// (e.g. 16-bit and 24-bit at 44.1kHz); picking the one that matches
    /// the source avoids the mixer silently padding/truncating samples.

    func outputStreamIDs(of deviceID: AudioDeviceID) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioDevicePropertyStreams size", status)
        }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { throw ControllerError.noOutputStreams }
        var streamIDs = [AudioStreamID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streamIDs)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioDevicePropertyStreams", status)
        }
        return streamIDs
    }

    func physicalFormat(of streamID: AudioStreamID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioStreamPropertyPhysicalFormat", status)
        }
        return asbd
    }

    func availablePhysicalFormats(of streamID: AudioStreamID) throws -> [AudioStreamRangedDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &size)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioStreamPropertyAvailablePhysicalFormats size", status)
        }
        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.size
        var formats = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: count)
        status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &formats)
        guard status == noErr else {
            throw ControllerError.propertyReadFailed("kAudioStreamPropertyAvailablePhysicalFormats", status)
        }
        return formats
    }

    /// Current bit depth of the device's first output stream, for display.
    func currentBitDepth(of deviceID: AudioDeviceID) -> Int? {
        guard let streamID = try? outputStreamIDs(of: deviceID).first,
              let asbd = try? physicalFormat(of: streamID),
              asbd.mBitsPerChannel > 0 else { return nil }
        return Int(asbd.mBitsPerChannel)
    }

    /// Sets every output stream's physical format to `bitDepth` at
    /// `sampleRate` where the device offers that combination, preferring an
    /// exact bit-depth match, then the closest higher depth (never
    /// truncating below the source), then the closest depth available.
    /// Streams with no linear-PCM format at `sampleRate` are left alone.
    @discardableResult
    func matchBitDepth(of deviceID: AudioDeviceID, sampleRate: Double, bitDepth: Int) throws -> Int? {
        var appliedBitDepth: Int?

        for streamID in try outputStreamIDs(of: deviceID) {
            let candidates = try availablePhysicalFormats(of: streamID).filter { ranged in
                ranged.mFormat.mFormatID == kAudioFormatLinearPCM
                    && ranged.mFormat.mBitsPerChannel > 0
                    && sampleRate >= ranged.mSampleRateRange.mMinimum - 1
                    && sampleRate <= ranged.mSampleRateRange.mMaximum + 1
            }
            guard !candidates.isEmpty else { continue }

            let target = bestBitDepthMatch(bitDepth, in: candidates)
            var desired = target.mFormat
            desired.mSampleRate = sampleRate

            let current = try physicalFormat(of: streamID)
            if current.mSampleRate == desired.mSampleRate, current.mBitsPerChannel == desired.mBitsPerChannel {
                appliedBitDepth = Int(current.mBitsPerChannel)
                continue
            }

            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyPhysicalFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectSetPropertyData(streamID, &address, 0, nil, size, &desired)
            guard status == noErr else {
                throw ControllerError.propertyWriteFailed("kAudioStreamPropertyPhysicalFormat", status)
            }
            appliedBitDepth = Int(desired.mBitsPerChannel)
        }

        return appliedBitDepth
    }

    private func bestBitDepthMatch(
        _ bitDepth: Int, in candidates: [AudioStreamRangedDescription]
    ) -> AudioStreamRangedDescription {
        if let exact = candidates.first(where: { $0.mFormat.mBitsPerChannel == UInt32(bitDepth) }) {
            return exact
        }
        let higher = candidates.filter { $0.mFormat.mBitsPerChannel >= UInt32(bitDepth) }
        if let nearestHigher = higher.min(by: { $0.mFormat.mBitsPerChannel < $1.mFormat.mBitsPerChannel }) {
            return nearestHigher
        }
        return candidates.max(by: { $0.mFormat.mBitsPerChannel < $1.mFormat.mBitsPerChannel })!
    }

    // MARK: Hog mode (exclusive access)

    /// Taking "hog mode" stops other processes/the system mixer from opening
    /// the device concurrently, which is what lets a sample-rate change here
    /// stick instead of being fought by CoreAudio's shared mix engine.
    func setHogMode(of id: AudioDeviceID, owned: Bool) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = owned ? pid_t(ProcessInfo.processInfo.processIdentifier) : pid_t(-1)
        let size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, size, &pid)
        guard status == noErr else {
            throw ControllerError.propertyWriteFailed("kAudioDevicePropertyHogMode", status)
        }

        // Some hardware reports success for this write but never actually
        // takes ownership (built-in Mac audio, notably, doesn't support
        // Hog Mode at all). Read the property back rather than trusting
        // noErr — verified this matters even on real external DACs mid
        // device-ID churn (see CoreAudioController.deviceExists' doc
        // comment): a write can land on a device object that's already on
        // its way out.
        if owned {
            var readback = pid_t(-1)
            var readbackSize = UInt32(MemoryLayout<pid_t>.size)
            let readStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &readbackSize, &readback)
            guard readStatus == noErr, readback == ProcessInfo.processInfo.processIdentifier else {
                throw ControllerError.hogModeNotSupported
            }
        }
    }
}
