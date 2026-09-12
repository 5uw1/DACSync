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
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published var targetDeviceID: AudioDeviceID? {
        didSet { UserDefaults.standard.set(Int(targetDeviceID ?? 0), forKey: Keys.targetDevice) }
    }
    @Published private(set) var currentSampleRate: Double?
    @Published private(set) var lastDetectedFormat: DetectedFormat?
    @Published private(set) var statusMessage: String = "Starting…"
    @Published private(set) var recentLogLines: [String] = []

    private let audio = CoreAudioController()
    private let monitor = PlaybackFormatMonitor()

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
    }

    func refreshDevices() {
        do {
            outputDevices = try audio.outputDevices()
            if targetDeviceID == nil {
                targetDeviceID = try? audio.defaultOutputDevice().id
            }
            if let id = targetDeviceID {
                currentSampleRate = try? audio.nominalSampleRate(of: id)
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

        do {
            let applied = try audio.matchSampleRate(of: deviceID, toSourceRate: format.sampleRate)
            currentSampleRate = applied
            let bitText = format.bitDepth.map { "\($0)-bit/" } ?? ""
            let renditionText = format.rendition.map { " (\($0))" } ?? ""
            statusMessage = "Matched \(bitText)\(Int(format.sampleRate)) Hz\(renditionText) → device now at \(Int(applied)) Hz"
        } catch {
            statusMessage = "Rate switch failed: \(error.localizedDescription)"
        }
    }

    private func applyHogMode() {
        guard let deviceID = targetDeviceID else { return }
        do {
            try audio.setHogMode(of: deviceID, owned: exclusiveAccessEnabled)
        } catch {
            statusMessage = "Exclusive access failed: \(error.localizedDescription)"
        }
    }
}
