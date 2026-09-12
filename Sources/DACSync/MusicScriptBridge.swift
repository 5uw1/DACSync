import Foundation

/// Queries Apple Music directly via AppleScript for the sample rate of
/// whatever is currently playing.
///
/// This exists because `PlaybackFormatMonitor`'s `log stream` tap only sees
/// *new* log lines — it has no visibility into a track that was already
/// playing before DACSync (re)launched, so the device could sit at a
/// stale rate from a previous session indefinitely until the next track
/// change. `sample rate of current track` is an officially exposed
/// AppleScript property (confirmed live: reports 96000 for a Hi-Res
/// Lossless track) and works regardless of when DACSync started, closing
/// that gap. It does not expose bit depth, so this is a sample-rate-only
/// safety net alongside the log-based detection, not a replacement.
enum MusicScriptBridge {
    static func currentTrackSampleRate() -> Double? {
        let script = """
        tell application "Music"
            if player state is playing then
                sample rate of current track
            end if
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rate = Double(output), rate > 0 else {
            return nil
        }
        return rate
    }
}
