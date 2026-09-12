import Combine
import CoreAudio
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var autoSwitchEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoSwitchEnabled, forKey: Keys.autoSwitch) }
    }
    @Published var exclusiveAccessEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(exclusiveAccessEnabled, forKey: Keys.exclusiveAccess)
            applyHogMode()
        }
    }
    @Published private(set) var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published var targetDeviceID: AudioDeviceID? {
        didSet { UserDefaults.standard.set(Int(targetDeviceID ?? 0), forKey: Keys.targetDevice) }
    }
    @Published private(set) var currentSampleRate: Double?
    @Published private(set) var currentBitDepth: Int?
    /// Whether hog mode actually took, as opposed to `exclusiveAccessEnabled`
    /// which only reflects the user's request. Some hardware (built-in Mac
    /// speakers, notably) reports the request as successful but never
    /// really takes ownership — see `CoreAudioController.setHogMode`.
    @Published private(set) var exclusiveAccessActuallyHeld: Bool = false
    @Published private(set) var lastDetectedFormat: DetectedFormat?
    @Published private(set) var statusMessage: String = "Starting…"

    /// Compact menu bar label — "44K", "96K", or "96K/24" once bit depth is
    /// actually being switched (exclusive access held).
    var menuBarTitle: String {
        guard let rate = currentSampleRate else { return "PureRate" }
        let khz = Int((rate / 1000).rounded())
        if exclusiveAccessActuallyHeld, let bitDepth = currentBitDepth {
            return "\(khz)K/\(bitDepth)"
        }
        return "\(khz)K"
    }
    @Published private(set) var recentLogLines: [String] = []

    private let audio = CoreAudioController()
    private let monitor = PlaybackFormatMonitor()

    /// A single track start emits several duplicate format-change log lines
    /// within ~100ms (FigStreamPlayer, ACAppleLosslessDecoder x2, ampplay).
    /// Without dedup this fires matchSampleRate/matchBitDepth 3-4x back to
    /// back for the identical (sampleRate, bitDepth) — wasted work that was
    /// also observed to trigger transient CoreAudio property-read errors
    /// from hammering the HAL that fast.
    private var lastAppliedKey: FormatKey?
    private var lastAppliedAt: Date?
    private struct FormatKey: Equatable {
        let sampleRate: Double
        let bitDepth: Int?
    }

    private enum Keys {
        static let autoSwitch = "autoSwitchEnabled"
        static let exclusiveAccess = "exclusiveAccessEnabled"
        static let targetDevice = "targetDeviceID"
    }

    init() {
        autoSwitchEnabled = UserDefaults.standard.object(forKey: Keys.autoSwitch) as? Bool ?? true
        exclusiveAccessEnabled = UserDefaults.standard.bool(forKey: Keys.exclusiveAccess)
        let savedDevice = UserDefaults.standard.integer(forKey: Keys.targetDevice)
        targetDeviceID = savedDevice == 0 ? nil : AudioDeviceID(savedDevice)

        refreshDevices()
        wireMonitor()
        // Start immediately at launch — MenuBarExtra's content closure (and
        // therefore MenuBarView's .onAppear) only evaluates once the user
        // opens the menu, which would otherwise leave monitoring off by
        // default for however long until that first click.
        startMonitoring()
        // didSet doesn't fire for a property's first assignment, so
        // restoring exclusiveAccessEnabled = true from UserDefaults above
        // silently would never actually take hog mode — apply it explicitly.
        if exclusiveAccessEnabled {
            applyHogMode()
        }

        audio.startWatchingDeviceListChanges { [weak self] in
            self?.handleDeviceListChanged()
        }
    }

    /// Re-resolves `targetDeviceID` when the system's device list changes
    /// and our cached ID no longer refers to a live device — notably after
    /// a physical-format (bit depth) change re-enumerates the device under
    /// a new ID (see `CoreAudioController.deviceExists`). AudioDeviceID
    /// isn't stable across that, but the device's name still is, so that's
    /// how the replacement is found.
    private func handleDeviceListChanged() {
        let previousDevices = outputDevices
        outputDevices = (try? audio.outputDevices()) ?? previousDevices

        guard let deviceID = targetDeviceID else { return }
        guard !audio.deviceExists(deviceID) else {
            // Still alive — just refresh what we show for it.
            currentSampleRate = try? audio.nominalSampleRate(of: deviceID)
            currentBitDepth = audio.currentBitDepth(of: deviceID)
            return
        }

        let previousName = previousDevices.first(where: { $0.id == deviceID })?.name
        if let previousName, let match = outputDevices.first(where: { $0.name == previousName }) {
            targetDeviceID = match.id
            statusMessage = "\(match.name) reconnected under a new device ID"
        } else if let fallback = try? audio.defaultOutputDevice() {
            targetDeviceID = fallback.id
            statusMessage = "Previous output device disappeared — switched to \(fallback.name)"
        } else {
            targetDeviceID = nil
            return
        }

        // The new device object starts in whatever state the OS gives it —
        // re-apply exclusivity and the last known format rather than
        // leaving it on defaults until the next track change.
        if exclusiveAccessEnabled {
            applyHogMode()
        }
        if let format = lastDetectedFormat {
            // Bypass the dedup guard in handle(format:) — it's keyed on
            // (rate, bitDepth) alone, but the target device just changed
            // out from under it, so the "already applied" state no longer
            // reflects reality even though the format itself hasn't.
            lastAppliedKey = nil
            handle(format: format)
        } else if let newDeviceID = targetDeviceID {
            currentSampleRate = try? audio.nominalSampleRate(of: newDeviceID)
            currentBitDepth = audio.currentBitDepth(of: newDeviceID)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let error = LaunchAtLogin.setEnabled(enabled) {
            statusMessage = "Launch at Login failed: \(error.localizedDescription)"
        }
        // Reflect the system's actual status either way, rather than
        // assuming the request succeeded.
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func refreshDevices() {
        do {
            outputDevices = try audio.outputDevices()
            // A device ID persisted from a previous session (or one this
            // session cached before a physical-format change re-enumerated
            // it) can be stale — fall back rather than silently targeting
            // nothing real.
            if let id = targetDeviceID, !audio.deviceExists(id) {
                targetDeviceID = nil
            }
            if targetDeviceID == nil {
                targetDeviceID = try? audio.defaultOutputDevice().id
            }
            if let id = targetDeviceID {
                currentSampleRate = try? audio.nominalSampleRate(of: id)
                currentBitDepth = audio.currentBitDepth(of: id)
            }
        } catch {
            statusMessage = "Couldn't list output devices: \(error.localizedDescription)"
        }
    }

    func startMonitoring() {
        do {
            try monitor.start()
            statusMessage = "Watching Apple Music for format changes…"
        } catch {
            statusMessage = "Couldn't start log monitor: \(error.localizedDescription)"
        }
    }

    /// Called on graceful quit (see AppDelegate.applicationWillTerminate) —
    /// Foundation doesn't kill a Process's children when the parent exits,
    /// so without this the log stream child (and hog mode, if held) would
    /// outlive the app.
    func stopMonitoring() {
        monitor.stop()
        if exclusiveAccessActuallyHeld, let deviceID = targetDeviceID {
            try? audio.setHogMode(of: deviceID, owned: false)
        }
    }

    private func wireMonitor() {
        monitor.onFormatDetected = { [weak self] format in
            Task { @MainActor in self?.handle(format: format) }
        }
        monitor.onRenditionChanged = { [weak self] rendition in
            Task { @MainActor in self?.statusMessage = "Rendition: \(rendition)" }
        }
        monitor.onRawLine = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.recentLogLines.append(line)
                if self.recentLogLines.count > 200 {
                    self.recentLogLines.removeFirst(self.recentLogLines.count - 200)
                }
            }
        }
        monitor.onStopped = { [weak self] error in
            Task { @MainActor in
                self?.statusMessage = error?.localizedDescription ?? "Log monitor stopped."
            }
        }
    }

    private func handle(format: DetectedFormat) {
        lastDetectedFormat = format
        guard autoSwitchEnabled, let deviceID = targetDeviceID else { return }

        let key = FormatKey(sampleRate: format.sampleRate, bitDepth: format.bitDepth)
        if key == lastAppliedKey, let lastAppliedAt, Date().timeIntervalSince(lastAppliedAt) < 1.0 {
            return
        }
        lastAppliedKey = key
        lastAppliedAt = Date()

        do {
            let appliedRate = try audio.matchSampleRate(of: deviceID, toSourceRate: format.sampleRate)
            currentSampleRate = appliedRate

            // Bit depth lives on the stream's *physical* (hardware wire)
            // format rather than the device-wide nominal rate, and setting
            // it is only reliable once we own the device exclusively —
            // otherwise the shared mixer can just override it back.
            var appliedBitDepth: Int?
            if exclusiveAccessActuallyHeld, let bitDepth = format.bitDepth {
                appliedBitDepth = try audio.matchBitDepth(of: deviceID, sampleRate: appliedRate, bitDepth: bitDepth)
                currentBitDepth = appliedBitDepth
            }

            let sourceBitText = format.bitDepth.map { "\($0)-bit/" } ?? ""
            let renditionText = format.rendition.map { " (\($0))" } ?? ""
            let deviceText = appliedBitDepth.map { "\($0)-bit/\(Int(appliedRate)) Hz" } ?? "\(Int(appliedRate)) Hz"
            statusMessage = "Matched \(sourceBitText)\(Int(format.sampleRate)) Hz\(renditionText) → device now at \(deviceText)"
        } catch {
            statusMessage = "Rate switch failed: \(error.localizedDescription)"
        }
    }

    private func applyHogMode() {
        guard let deviceID = targetDeviceID else { return }
        do {
            try audio.setHogMode(of: deviceID, owned: exclusiveAccessEnabled)
            exclusiveAccessActuallyHeld = exclusiveAccessEnabled
            // Re-apply bit depth now that exclusivity just changed — either
            // we can finally set it reliably, or we just lost the device
            // and shouldn't keep pretending our last setting sticks.
            if exclusiveAccessActuallyHeld, let format = lastDetectedFormat, let bitDepth = format.bitDepth,
               let rate = currentSampleRate {
                currentBitDepth = try audio.matchBitDepth(of: deviceID, sampleRate: rate, bitDepth: bitDepth)
            } else {
                currentBitDepth = audio.currentBitDepth(of: deviceID)
            }
        } catch {
            exclusiveAccessActuallyHeld = false
            statusMessage = "Exclusive access failed: \(error.localizedDescription)"
        }
    }
}
