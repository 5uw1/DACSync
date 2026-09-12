import Combine
import CoreAudio
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var autoSwitchEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: Keys.autoSwitch)
            if !autoSwitchEnabled {
                restoreOriginalFormat(includeSampleRate: true)
            }
        }
    }
    // Not persisted — see the comment on this property's assignment in
    // init().
    @Published var exclusiveAccessEnabled: Bool = false {
        didSet { applyHogMode() }
    }
    @Published private(set) var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published var targetDeviceID: AudioDeviceID? {
        didSet {
            UserDefaults.standard.set(Int(targetDeviceID ?? 0), forKey: Keys.targetDevice)
            // Persist by name too — device IDs on this kind of hardware can
            // churn (see CoreAudioController.deviceExists' doc comment),
            // and more importantly the system's own "default output
            // device" pointer isn't trustworthy to fall back on either: a
            // nearby iPhone's Continuity microphone was observed
            // intermittently becoming the system default output, which
            // would otherwise hijack our fallback logic on next launch.
            // Re-matching by name is what actually keeps this pointed at
            // the device the user chose.
            if let id = targetDeviceID, let name = outputDevices.first(where: { $0.id == id })?.name {
                UserDefaults.standard.set(name, forKey: Keys.targetDeviceName)
            }
        }
    }
    @Published private(set) var currentSampleRate: Double?
    @Published private(set) var currentBitDepth: Int?
    /// Whether hog mode actually took, as opposed to `exclusiveAccessEnabled`
    /// which only reflects the user's request. Built-in Mac audio doesn't
    /// support Hog Mode at all, and even on hardware that does, a write can
    /// land on a device object mid-churn (see
    /// `CoreAudioController.deviceExists`) — see `CoreAudioController.setHogMode`.
    @Published private(set) var exclusiveAccessActuallyHeld: Bool = false
    @Published private(set) var lastDetectedFormat: DetectedFormat?
    @Published private(set) var statusMessage: String = "Starting…"

    /// Compact menu bar label — "44K", "96K", or "96K/24" once bit depth is
    /// actually being switched (exclusive access held).
    var menuBarTitle: String {
        guard let rate = currentSampleRate else { return "DACSync" }
        let khz = Int((rate / 1000).rounded())
        if exclusiveAccessActuallyHeld, let bitDepth = currentBitDepth {
            return "\(khz)K/\(bitDepth)"
        }
        return "\(khz)K"
    }
    @Published private(set) var recentLogLines: [String] = []

    struct SwitchLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let sampleRate: Double
        let bitDepth: Int?

        var displayText: String {
            let time = timestamp.formatted(date: .omitted, time: .standard)
            let khz = Int((sampleRate / 1000).rounded())
            let bitText = bitDepth.map { "\($0)-bit/" } ?? ""
            return "\(time) — \(bitText)\(khz)K"
        }
    }
    /// Only actual changes, newest first — not every detection event (a
    /// re-detected identical format, or a no-op restore, doesn't get an
    /// entry).
    @Published private(set) var switchHistory: [SwitchLogEntry] = []

    private func logSwitchIfChanged(sampleRate: Double, bitDepth: Int?) {
        if let last = switchHistory.first, abs(last.sampleRate - sampleRate) < 1, last.bitDepth == bitDepth {
            return
        }
        switchHistory.insert(SwitchLogEntry(timestamp: Date(), sampleRate: sampleRate, bitDepth: bitDepth), at: 0)
        if switchHistory.count > 50 {
            switchHistory.removeLast(switchHistory.count - 50)
        }
    }

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

    /// The device's own format, captured before DACSync first touches it,
    /// so turning auto-switch/exclusive access back off can put it back
    /// rather than leaving it stuck at whatever was last forced. Keyed to
    /// the specific device ID: if the hardware re-enumerates (see
    /// CoreAudioController.deviceExists), there's no way to know the truly
    /// original state of the *new* ID, so it re-captures fresh — the best
    /// available fallback.
    private var originalFormatDeviceID: AudioDeviceID?
    private var originalSampleRate: Double?
    private var originalBitDepth: Int?

    private func captureOriginalFormatIfNeeded(for deviceID: AudioDeviceID) {
        guard originalFormatDeviceID != deviceID else { return }
        originalFormatDeviceID = deviceID
        originalSampleRate = try? audio.nominalSampleRate(of: deviceID)
        originalBitDepth = audio.currentBitDepth(of: deviceID)
    }

    /// Puts the target device back to its captured original format.
    /// `includeSampleRate: false` restores bit depth only — used when just
    /// exclusive access is released but auto-switch is still managing the
    /// sample rate.
    private func restoreOriginalFormat(includeSampleRate: Bool) {
        guard let deviceID = targetDeviceID else { return }
        lastAppliedKey = nil

        var rateForBitDepthMatch = currentSampleRate
        if includeSampleRate, let originalSampleRate {
            rateForBitDepthMatch = try? audio.matchSampleRate(of: deviceID, toSourceRate: originalSampleRate)
            currentSampleRate = rateForBitDepthMatch
        }

        if let originalBitDepth, let rate = rateForBitDepthMatch {
            currentBitDepth = try? audio.matchBitDepth(of: deviceID, sampleRate: rate, bitDepth: originalBitDepth)
        } else {
            currentBitDepth = audio.currentBitDepth(of: deviceID)
        }
        if let rate = currentSampleRate {
            logSwitchIfChanged(sampleRate: rate, bitDepth: currentBitDepth)
        }
        statusMessage = "Restored original format"
    }

    private enum Keys {
        static let autoSwitch = "autoSwitchEnabled"
        static let targetDevice = "targetDeviceID"
        static let targetDeviceName = "targetDeviceName"
    }

    init() {
        autoSwitchEnabled = UserDefaults.standard.object(forKey: Keys.autoSwitch) as? Bool ?? true
        // Deliberately NOT restored from UserDefaults — exclusive access
        // silences audio by design when it's held by DACSync instead of
        // whatever's actually playing (see the MenuBarView warning next to
        // this toggle). Every session starts with it off; turning it on is
        // a conscious per-session choice, not something that should
        // silently carry over and surprise a future launch.
        exclusiveAccessEnabled = false
        let savedDevice = UserDefaults.standard.integer(forKey: Keys.targetDevice)
        targetDeviceID = savedDevice == 0 ? nil : AudioDeviceID(savedDevice)

        refreshDevices()
        wireMonitor()
        // Start immediately at launch — MenuBarExtra's content closure (and
        // therefore MenuBarView's .onAppear) only evaluates once the user
        // opens the menu, which would otherwise leave monitoring off by
        // default for however long until that first click.
        startMonitoring()

        audio.startWatchingDeviceListChanges { [weak self] in
            self?.handleDeviceListChanged()
        }

        // The log tap only sees *new* lines, so a track already playing
        // before launch is otherwise invisible until the next track
        // change — sync with reality immediately, then periodically as a
        // safety net (covers e.g. resuming a paused track, which doesn't
        // re-emit the format-change log lines a fresh track start does).
        syncWithCurrentlyPlayingTrack()
        appleScriptSyncTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncWithCurrentlyPlayingTrack() }
        }
    }

    private var appleScriptSyncTimer: Timer?

    private func syncWithCurrentlyPlayingTrack() {
        Task {
            // Only the blocking AppleScript call needs to leave the main
            // actor; back on it afterward, `self` is used normally.
            let rateTask = Task.detached { MusicScriptBridge.currentTrackSampleRate() }
            guard let rate = await rateTask.value else {
                return
            }
            // Doesn't tell us bit depth — only closes the sample-rate gap.
            // A real log-detected event fills in bit depth once the next
            // natural track change happens.
            let format = DetectedFormat(
                sampleRate: rate, bitDepth: nil, rendition: nil,
                rawLine: "(synced via AppleScript)", timestamp: Date()
            )
            handle(format: format)
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

    /// Tries to point `targetDeviceID` at whatever currently-enumerated
    /// output device matches the persisted device name. Re-scans fresh
    /// each call (rather than trusting a possibly-stale `outputDevices`)
    /// since this is also used from a delayed retry.
    @discardableResult
    private func resolveByPersistedName() -> Bool {
        guard let persistedName = UserDefaults.standard.string(forKey: Keys.targetDeviceName) else { return false }
        outputDevices = (try? audio.outputDevices()) ?? outputDevices
        guard let match = outputDevices.first(where: { $0.name == persistedName }) else { return false }
        targetDeviceID = match.id
        return true
    }

    func refreshDevices() {
        do {
            outputDevices = try audio.outputDevices()
            // A device ID persisted from a previous session (or one this
            // session cached before a physical-format change re-enumerated
            // it) can be stale — re-resolve rather than silently targeting
            // nothing real.
            if let id = targetDeviceID, !audio.deviceExists(id) {
                targetDeviceID = nil
            }

            if targetDeviceID == nil {
                // Prefer matching the persisted device *name* over the
                // system's own default-output pointer: on this kind of
                // multi-device setup that pointer isn't trustworthy either
                // (a nearby iPhone's Continuity microphone was observed
                // intermittently becoming the system default output), and
                // would otherwise hijack the target away from the device
                // the user actually picked. Runs whether we just lost a
                // live target above or simply never had a resolved ID yet
                // (e.g. only a name was persisted).
                if !resolveByPersistedName() {
                    if UserDefaults.standard.string(forKey: Keys.targetDeviceName) != nil {
                        // Have a name to retry toward — releasing hog mode
                        // on quit is itself what makes some DACs briefly
                        // reset their USB interface, so relaunching right
                        // after a quit can race that reset and catch the
                        // device mid-disappearance. Retry shortly before
                        // falling back to (the not fully trustworthy)
                        // system default.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                            guard let self else { return }
                            if !self.resolveByPersistedName(), self.targetDeviceID == nil {
                                self.targetDeviceID = try? self.audio.defaultOutputDevice().id
                            }
                            if self.exclusiveAccessEnabled {
                                self.applyHogMode()
                            }
                        }
                    } else {
                        // No prior device preference at all (first launch)
                        // — fine to trust system default here since
                        // there's no better signal to retry toward.
                        targetDeviceID = try? audio.defaultOutputDevice().id
                    }
                }
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
        appleScriptSyncTimer?.invalidate()
        appleScriptSyncTimer = nil
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
        captureOriginalFormatIfNeeded(for: deviceID)

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

            logSwitchIfChanged(sampleRate: appliedRate, bitDepth: appliedBitDepth)

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
        captureOriginalFormatIfNeeded(for: deviceID)
        do {
            try audio.setHogMode(of: deviceID, owned: exclusiveAccessEnabled)
            exclusiveAccessActuallyHeld = exclusiveAccessEnabled
            // Re-apply bit depth now that exclusivity just changed — either
            // we can finally set it reliably, or we just released it and
            // should put the device's bit depth back rather than leaving
            // it stuck at whatever was last forced.
            if exclusiveAccessActuallyHeld, let format = lastDetectedFormat, let bitDepth = format.bitDepth,
               let rate = currentSampleRate {
                currentBitDepth = try audio.matchBitDepth(of: deviceID, sampleRate: rate, bitDepth: bitDepth)
            } else if !exclusiveAccessEnabled {
                restoreOriginalFormat(includeSampleRate: false)
            } else {
                currentBitDepth = audio.currentBitDepth(of: deviceID)
            }
        } catch {
            exclusiveAccessActuallyHeld = false
            statusMessage = "Exclusive access failed: \(error.localizedDescription)"
        }
    }
}
