import Foundation

struct DetectedFormat: Equatable {
    let sampleRate: Double
    let bitDepth: Int?
    /// "lossless", "hiResLossless", etc. — from Music's own PBAudioFormat
    /// enum where the line carries one; nil otherwise.
    let rendition: String?
    let rawLine: String
    let timestamp: Date
}

/// Parses a single unified-logging line into a playback format.
///
/// These patterns were reverse-engineered by capturing real `log stream`
/// output from Music.app on macOS 26.6 while switching between a lossy
/// (AAC) track, a CD-quality Lossless track (44.1kHz/16-bit) and a Hi-Res
/// Lossless track (96kHz/24-bit). All three numeric patterns below only
/// ever appeared while an ALAC (Apple Lossless) stream was actually being
/// decoded — the AAC track produced none of them — so a match here is
/// inherently a lossless-playback signal; no extra "is this lossless"
/// check is needed downstream.
///
/// Apple doesn't publish these strings, so a future macOS/Music update can
/// change them. If matches stop appearing, recapture with:
/// ```
/// log stream --style compact --level debug --predicate \
///   'process == "Music" AND (eventMessage CONTAINS "BitDepth" OR ' \
///   'eventMessage CONTAINS "ACAppleLosslessDecoder" OR ' \
///   'eventMessage CONTAINS "PBAudioFormat" OR eventMessage CONTAINS "mediaFormatinfo")'
/// ```
enum FormatLineParser {
    // "... sdFormatID = alac, high res lossless, ... sdBitDepth = 24 bit,
    //  asbdSampleRate = 96.0 kHz, ..." — richest single line: both numbers
    // and a human-readable rendition together.
    private static let ampPlayPattern = try! NSRegularExpression(
        pattern: #"sdFormatID = alac,\s*([a-z ]+?),.*?sdBitDepth = (\d+) bit,\s*asbdSampleRate = ([\d.]+) kHz"#,
        options: .caseInsensitive
    )

    // "... [Rendition Lossless] [SampleRate 96000] [BitDepth 24] ..."
    private static let figStreamPattern = try! NSRegularExpression(
        pattern: #"\[Rendition ([^\]]+)\]\s*\[SampleRate (\d+)\]\s*\[BitDepth (\d+)\]"#,
        options: .caseInsensitive
    )

    // "... Input format:  2 ch,  96000 Hz, alac (0x00000003) from 24-bit source, ..."
    private static let alacDecoderPattern = try! NSRegularExpression(
        pattern: #"(\d+)\s?Hz,\s?alac.*?from\s?(\d+)-bit source"#, options: .caseInsensitive
    )

    // "Audio format changed to PBAudioFormat.hiResLossless." — rendition
    // label only, no numbers. Useful for the UI, and to notice playback
    // dropping to "other" (lossy) — the three patterns above never fire
    // for that case anyway, so this isn't needed as a switching gate.
    private static let renditionChangePattern = try! NSRegularExpression(
        pattern: #"Audio format changed to PBAudioFormat\.(\w+)"#, options: .caseInsensitive
    )

    static func parse(_ line: String) -> DetectedFormat? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        if let m = ampPlayPattern.firstMatch(in: line, range: range),
           let bitDepth = Int(line[Range(m.range(at: 2), in: line)!]),
           let sampleRateKHz = Double(line[Range(m.range(at: 3), in: line)!]) {
            let rendition = String(line[Range(m.range(at: 1), in: line)!]).trimmingCharacters(in: .whitespaces)
            return DetectedFormat(
                sampleRate: sampleRateKHz * 1000, bitDepth: bitDepth,
                rendition: rendition, rawLine: line, timestamp: Date()
            )
        }

        if let m = figStreamPattern.firstMatch(in: line, range: range),
           let sampleRate = Double(line[Range(m.range(at: 2), in: line)!]),
           let bitDepth = Int(line[Range(m.range(at: 3), in: line)!]) {
            let rendition = String(line[Range(m.range(at: 1), in: line)!])
            return DetectedFormat(
                sampleRate: sampleRate, bitDepth: bitDepth,
                rendition: rendition, rawLine: line, timestamp: Date()
            )
        }

        if let m = alacDecoderPattern.firstMatch(in: line, range: range),
           let sampleRate = Double(line[Range(m.range(at: 1), in: line)!]),
           let bitDepth = Int(line[Range(m.range(at: 2), in: line)!]) {
            return DetectedFormat(
                sampleRate: sampleRate, bitDepth: bitDepth,
                rendition: nil, rawLine: line, timestamp: Date()
            )
        }

        return nil
    }

    /// Rendition-only signal (no sample rate/bit depth) — e.g. "lossless",
    /// "hiResLossless", "other" (AAC/lossy), "dolbyAtmos".
    static func parseRenditionChange(_ line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = renditionChangePattern.firstMatch(in: line, range: range) else { return nil }
        return String(line[Range(m.range(at: 1), in: line)!])
    }
}

/// Streams unified log entries from Music.app by shelling out to
/// `/usr/bin/log stream`, the same general approach LosslessSwitcher
/// (github.com/vincentneo/LosslessSwitcher) uses. The matching lines are
/// only emitted at Debug level, and reading the live unified log at all
/// requires the running user to be an admin (same requirement
/// LosslessSwitcher documents).
final class PlaybackFormatMonitor {
    private static let predicate = """
    process == "Music" AND (eventMessage CONTAINS "BitDepth" OR eventMessage CONTAINS "ACAppleLosslessDecoder" OR eventMessage CONTAINS "PBAudioFormat" OR eventMessage CONTAINS "mediaFormatinfo")
    """

    private var process: Process?
    private var stdoutPipe: Pipe?

    var onFormatDetected: ((DetectedFormat) -> Void)?
    var onRenditionChanged: ((String) -> Void)?
    var onRawLine: ((String) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--level", "debug", "--predicate", Self.predicate]

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
        onRawLine?(line)
        if let format = FormatLineParser.parse(line) {
            onFormatDetected?(format)
        } else if let rendition = FormatLineParser.parseRenditionChange(line) {
            onRenditionChanged?(rendition)
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
