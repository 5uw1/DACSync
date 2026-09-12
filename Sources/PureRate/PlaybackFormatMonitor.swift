import Foundation

struct DetectedFormat: Equatable {
    let sampleRate: Double
    let bitDepth: Int?
    let rawLine: String
    let timestamp: Date
}

/// Parses a single unified-logging line into a playback format, if it looks
/// like one. Kept separate from the log-streaming plumbing so the regexes
/// can be tuned against real captured log lines without touching Process
/// handling.
///
/// NOTE: Apple does not publish the log strings Music.app emits for the
/// current track's sample rate / bit depth, so these patterns are a
/// best-effort match on the "44.1kHz / 24-bit" style text apps in this
/// space (e.g. LosslessSwitcher) are known to scrape. Capture real lines
/// with `log stream` while playing a Lossless track and adjust the
/// patterns below if matches are missing.
enum FormatLineParser {
    private static let kHzPattern = try! NSRegularExpression(
        pattern: #"(\d{2,3}(?:\.\d)?)\s?kHz"#, options: .caseInsensitive
    )
    private static let hzPattern = try! NSRegularExpression(
        pattern: #"(\d{4,6})\s?Hz"#, options: .caseInsensitive
    )
    private static let bitDepthPattern = try! NSRegularExpression(
        pattern: #"(\d{1,2})[\s-]?bit"#, options: .caseInsensitive
    )

    static func parse(_ line: String) -> DetectedFormat? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        var sampleRate: Double?
        if let match = kHzPattern.firstMatch(in: line, range: range),
           let value = Double(line[Range(match.range(at: 1), in: line)!]) {
            sampleRate = value * 1000
        } else if let match = hzPattern.firstMatch(in: line, range: range),
                  let value = Double(line[Range(match.range(at: 1), in: line)!]) {
            sampleRate = value
        }

        guard let sampleRate else { return nil }

        var bitDepth: Int?
        if let match = bitDepthPattern.firstMatch(in: line, range: range) {
            bitDepth = Int(line[Range(match.range(at: 1), in: line)!])
        }

        return DetectedFormat(sampleRate: sampleRate, bitDepth: bitDepth, rawLine: line, timestamp: Date())
    }

    /// Loose filter used to keep candidate lines in the debug panel even
    /// when `parse` can't fully extract a rate, so the regexes above can be
    /// refined against what Music.app is actually logging on this machine.
    static func looksAudioRelated(_ line: String) -> Bool {
        let needles = ["kHz", "Hz", "bit", "ALAC", "sample rate", "sampleRate", "AudioFormat"]
        return needles.contains { line.localizedCaseInsensitiveContains($0) }
    }
}

/// Streams unified log entries from the Music app (and the daemons it hands
/// decoding off to) by shelling out to `/usr/bin/log stream`, the same
/// approach LosslessSwitcher (github.com/vincentneo/LosslessSwitcher) uses.
/// Reading the *historical* unified log store programmatically needs the
/// running user to be an admin; `log stream`'s live mode inherits the same
/// requirement.
final class PlaybackFormatMonitor {
    private static let predicate = """
    (process == "Music") OR (process == "amp-syncd") OR (subsystem CONTAINS "com.apple.Music")
    """

    private var process: Process?
    private var stdoutPipe: Pipe?

    var onFormatDetected: ((DetectedFormat) -> Void)?
    var onRawLine: ((String) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--level", "info", "--predicate", Self.predicate]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            chunk.enumerateLines { line, _ in
                self?.handle(line: line)
            }
        }

        process.terminationHandler = { [weak self] proc in
            self?.isRunning = false
            self?.onStopped?(proc.terminationStatus == 0 ? nil : LogStreamError.nonZeroExit(proc.terminationStatus))
        }

        try process.run()
        self.process = process
        self.stdoutPipe = pipe
        isRunning = true
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        isRunning = false
    }

    private func handle(line: String) {
        if FormatLineParser.looksAudioRelated(line) {
            onRawLine?(line)
        }
        if let format = FormatLineParser.parse(line) {
            onFormatDetected?(format)
        }
    }

    enum LogStreamError: Error, LocalizedError {
        case nonZeroExit(Int32)

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let code):
                return "`log stream` exited with status \(code). Ensure this user account is an admin — reading the unified log requires it."
            }
        }
    }
}
