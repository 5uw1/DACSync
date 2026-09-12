import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @State private var showDebugLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PureRate").font(.headline)

            Toggle("Auto-switch sample rate", isOn: $state.autoSwitchEnabled)
            Toggle("Take exclusive access (hog mode)", isOn: $state.exclusiveAccessEnabled)

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
                Text("Device rate: \(Int(rate)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Button("Quit PureRate") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
