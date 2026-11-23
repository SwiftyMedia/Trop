//
//  LyricsProvider.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import Foundation

/// A normalized query used to look up lyrics across providers
struct LyricsQuery: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let videoId: String?

    /// `nil` means the player has not resolved a trustworthy duration yet.
    /// Providers must not send `0` as if it were a real track length.
    var durationSeconds: Int? {
        guard duration > 0 else { return nil }
        return Int(duration)
    }
}

/// Shared matching rules based on Metrolist's MusicVideoMatcher. Keeping these
/// rules in one place prevents each provider from accepting a different song.
enum LyricsMatching {
    private static let decoratorPattern = #"(?i)\b(?:official|video|lyrics?|mv|m/v|hd|hq|4k|visualizer|visualiser|audio\s+only|sing[- ]?along)\b"#
    private static let disqualifyingVariants = ["live", "remix", "acoustic", "instrumental", "karaoke", "sped up", "slowed", "nightcore", "cover"]

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\[\]{}()<>「」『』【】]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func coreTitle(_ value: String) -> String {
        let withoutDecorators = value
            .replacingOccurrences(of: #"(?i)[(\[\{](?:[^)\]}]*)(?:\)|\]|\})"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: decoratorPattern, with: " ", options: .regularExpression)
        return normalize(withoutDecorators)
    }

    static func titleMatches(_ requested: String, _ candidate: String) -> Bool {
        let requestedNormalized = normalize(requested)
        let candidateNormalized = normalize(candidate)
        guard !requestedNormalized.isEmpty, !candidateNormalized.isEmpty else { return false }
        if requestedNormalized == candidateNormalized { return true }
        if isDisqualifiedVariant(requested, candidate) { return false }
        return coreTitle(requested) == coreTitle(candidate)
    }

    static func artistMatches(_ requested: String, _ candidate: String) -> Bool {
        let requestedNames = names(requested)
        let candidateNames = names(candidate)
        guard !requestedNames.isEmpty, !candidateNames.isEmpty else { return requestedNames.isEmpty }
        return requestedNames.contains { wanted in
            candidateNames.contains { found in
                wanted == found || (wanted.count >= 4 && found.count >= 4 && (wanted.contains(found) || found.contains(wanted)))
            }
        }
    }

    static func durationMatches(_ requested: Int?, _ candidate: Double, tolerance: Double = 10) -> Bool {
        guard let requested, requested > 0, candidate > 0 else { return true }
        return abs(candidate - Double(requested)) <= tolerance
    }

    static func isDisqualifiedVariant(_ requested: String, _ candidate: String) -> Bool {
        let wanted = normalize(requested)
        let found = normalize(candidate)
        return disqualifyingVariants.contains { found.contains($0) && !wanted.contains($0) }
    }

    private static func names(_ value: String) -> [String] {
        value
            .components(separatedBy: ",")
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace || $0 == "&" || $0 == "/" || $0 == "+" }) }
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}

/// Common interface implemented by every lyrics source.
protocol LyricsProvider: Sendable {
    var id: String { get }
    var name: String { get }
    func fetch(query: LyricsQuery) async throws -> [LyricLine]
}

enum LyricsParsing {
    /// Parses an `[mm:ss.xx]` or `[mm:ss]` timestamp at the start of a line.
    /// Enhanced LRC also carries inline `<mm:ss.xx>` word tags; those are
    /// stripped from the text, and a line that only has word tags still gets
    /// its start time from the first one.
    static func parseLrcTimestamp(_ line: String) -> (time: TimeInterval, text: String)? {
        // Match one or more leading [..] tags
        let pattern = #"^(?:\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\])+"#
        let fullRange = NSRange(line.startIndex..., in: line)
        let time: TimeInterval
        let textStart: String.Index

        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: fullRange) {
            // The last matched tag holds the time we care about
            let tagPattern = #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
            guard let tagRegex = try? NSRegularExpression(pattern: tagPattern),
                  let last = tagRegex.matches(in: line, range: fullRange).last else { return nil }
            time = timestamp(in: line, match: last)
            textStart = line.index(line.startIndex, offsetBy: match.range.location + match.range.length)
        } else if let wordTag = firstWordTag(in: line) {
            // Word-synced line without a line-level tag (e.g. some SimpMusic
            // rich-sync payloads).
            time = wordTag.time
            textStart = wordTag.end
        } else {
            return nil
        }

        return (time, cleanLrcText(String(line[textStart...])))
    }

    /// Time for a `[mm:ss.xx]`-style tag match (groups: minutes, seconds, fraction).
    private static func timestamp(in line: String, match: NSTextCheckingResult) -> TimeInterval {
        let ns = line as NSString
        let mins = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let secs = Int(ns.substring(with: match.range(at: 2))) ?? 0
        let fracRange = match.range(at: 3)
        let fracStr = fracRange.location != NSNotFound ? ns.substring(with: fracRange) : ""
        // Normalize fractional part to seconds (supports 1-3 digit fractions)
        let frac = fracStr.isEmpty ? 0 : (Double("0.\(fracStr)") ?? 0)
        return TimeInterval(mins * 60 + secs) + frac
    }

    private static func firstWordTag(in line: String) -> (time: TimeInterval, end: String.Index)? {
        let pattern = #"^\s*<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let end = Range(match.range, in: line)?.upperBound else { return nil }
        return (timestamp(in: line, match: match), end)
    }

    /// Removes enhanced-LRC word tags and normalizes the leftover spacing.
    static func cleanLrcText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Split a raw LRC string into lines. Blank timestamped lines are kept —
    /// they mark instrumental spans (like Metrolist's isBlank entries).
    static func parseLrc(_ raw: String) -> [LyricLine] {
        raw.split(whereSeparator: \.isNewline).map(String.init).compactMap { line in
            guard let (time, text) = parseLrcTimestamp(line) else { return nil }
            return LyricLine(text: text, startTime: time)
        }
    }

    /// Parses stored lyrics text — LRC if timestamped, otherwise plain lines.
    static func parseStoredText(_ raw: String) -> [LyricLine] {
        let lrc = parseLrc(raw)
        if !lrc.isEmpty { return lrc }
        return raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(text: $0, startTime: nil) }
    }

    /// Serializes lines back to LRC/plain text for storage and editing.
    static func serializeLines(_ lines: [LyricLine]) -> String {
        let synced = lines.contains { $0.startTime != nil }
        return lines.map { line in
            guard synced, let t = line.startTime else { return line.text }
            let minutes = Int(t) / 60
            let seconds = Int(t) % 60
            let centis = Int((t - floor(t)) * 100)
            return String(format: "[%02d:%02d.%02d]", minutes, seconds, centis) + line.text
        }
        .joined(separator: "\n")
    }

    /// Plain text without timestamps — what "Copy" puts on the clipboard.
    static func plainText(_ lines: [LyricLine]) -> String {
        lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
