import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @State private var showDebugLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DACSync").font(.headline)

            Toggle("Auto-switch sample rate", isOn: $state.autoSwitchEnabled)
            Toggle("Take exclusive access (hog mode)", isOn: $state.exclusiveAccessEnabled)
            if state.exclusiveAccessEnabled {
                Text("⚠️ May silence audio: DACSync isn't the app playing your music, so holding exclusive access can block Apple Music from using the device. Off is safest — this doesn't persist between launches.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Toggle("Launch at login", isOn: Binding(
                get: { state.launchAtLoginEnabled },
                set: { state.setLaunchAtLogin($0) }
            ))

            Divider()

            Picker("Output device", selection: Binding(
                get: { state.targetDeviceID },
                set: { state.targetDeviceID = $0 }
            )) {
                ForEach(state.outputDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()

            if let rate = state.currentSampleRate {
                let bitText = state.currentBitDepth.map { "\($0)-bit / " } ?? ""
                Text("Device: \(bitText)\(Int(rate)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if state.exclusiveAccessEnabled && !state.exclusiveAccessActuallyHeld {
                Text("Exclusive access not held by this device yet — bit depth won't switch until it is (built-in Mac audio never supports this; retrying automatically on an external DAC)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if !state.exclusiveAccessEnabled {
                Text("Bit depth only switches under exclusive access")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let format = state.lastDetectedFormat {
                let bitText = format.bitDepth.map { "\($0)-bit / " } ?? ""
                let renditionText = format.rendition.map { " (\($0))" } ?? ""
                Text("Last detected: \(bitText)\(Int(format.sampleRate)) Hz\(renditionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(state.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Divider()

            Button(state.outputDevices.isEmpty ? "Refresh devices" : "Refresh devices") {
                state.refreshDevices()
            }

            Toggle("Show raw log matches", isOn: $showDebugLog)

            if showDebugLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.recentLogLines.suffix(20).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                }
                .frame(height: 140)
            }

            Divider()

            Button("Quit DACSync") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
