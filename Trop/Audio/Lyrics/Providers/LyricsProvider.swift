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

    var durationSeconds: Int { Int(duration) }
}

/// Common interface implemented by every lyrics source.
protocol LyricsProvider: Sendable {
    var id: String { get }
    var name: String { get }
    func fetch(query: LyricsQuery) async throws -> [LyricLine]
}

enum LyricsParsing {
    /// Parses an `[mm:ss.xx]` or `[mm:ss]` timestamp at the start of a line
    static func parseLrcTimestamp(_ line: String) -> (time: TimeInterval, text: String)? {
        // Match one or more leading [..] tags
        let pattern = #"^(?:\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\])+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }

        // The last matched tag holds the time we care about
        let tagPattern = #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#
        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern) else { return nil }
        let tagMatches = tagRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard let last = tagMatches.last else { return nil }
        let time = timestampComponents(
            mins: (line as NSString).substring(with: last.range(at: 1)),
            secs: (line as NSString).substring(with: last.range(at: 2)),
            frac: last.range(at: 3).location != NSNotFound
                ? (line as NSString).substring(with: last.range(at: 3))
                : "0"
        )

        let end = match.range.location + match.range.length
        let text = String(line[line.index(line.startIndex, offsetBy: end)...])
            .trimmingCharacters(in: .whitespaces)
        return (time, text)
    }

    /// Split a raw LRC string into lines. Blank timestamped lines are kept —
    /// they mark instrumental spans (like Metrolist's isBlank entries).
    /// Enhanced LRC word tags (`<mm:ss.xx>`) are parsed into `LyricWord`s when present.
    static func parseLrc(_ raw: String) -> [LyricLine] {
        raw.split(whereSeparator: \.isNewline).map(String.init).compactMap { line in
            guard let (time, text) = parseLrcTimestamp(line) else { return nil }
            let (plain, words) = parseEnhancedWordTags(in: text)
            return LyricLine(text: plain, startTime: time, words: words)
        }
    }

    /// NetEase YRC word-timed lyrics.
    /// Line: `[startMs,durationMs](wordStartMs,wordDurMs,0)word...`
    /// Also accepts JSON metadata lines: `{"t":ms,"c":[{"tx":"…","tr":[off,dur]}…]}`.
    static func parseYrc(_ raw: String) -> [LyricLine] {
        raw.split(whereSeparator: \.isNewline).map(String.init).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("{") {
                return parseYrcJSONLine(trimmed)
            }
            return parseYrcBracketLine(trimmed)
        }
    }

    /// Parses stored lyrics text — LRC/YRC if timestamped, otherwise plain lines.
    static func parseStoredText(_ raw: String) -> [LyricLine] {
        if raw.contains("]("), let yrc = optionalNonEmpty(parseYrc(raw)) {
            return yrc
        }
        let lrc = parseLrc(raw)
        if !lrc.isEmpty { return lrc }
        return raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(text: $0, startTime: nil) }
    }

    /// Serializes lines back to LRC/plain text for storage and editing.
    /// Word timings are written as Enhanced LRC `<mm:ss.xx>` tags when present.
    static func serializeLines(_ lines: [LyricLine]) -> String {
        let synced = lines.contains {
            $0.startTime != nil || ($0.words?.count ?? 0) >= 2
        }
        return lines.map { line in
            // Prefer line start; fall back to first word so word-timed lines
            // at t=0 (or with a nil start) are not written as plain text.
            let t = line.startTime ?? line.words?.first?.startTime
            guard synced, let t else { return line.text }
            let prefix = formatLrcTimestamp(t)
            if let words = line.words, words.count >= 2 {
                let body = words.map { formatEnhancedWordTag($0.startTime) + $0.text }.joined()
                return prefix + body
            }
            return prefix + line.text
        }
        .joined(separator: "\n")
    }

    /// Plain text without timestamps — what "Copy" puts on the clipboard.
    static func plainText(_ lines: [LyricLine]) -> String {
        lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Enhanced LRC word tags

    /// Extracts `<mm:ss.xx>word` segments. Returns the concatenated plain text and
    /// word timings when at least two timed words are present.
    static func parseEnhancedWordTags(in text: String) -> (text: String, words: [LyricWord]?) {
        let pattern = #"<(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, nil)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return (text, nil) }

        var words: [LyricWord] = []
        var plain = ""
        for (index, match) in matches.enumerated() {
            let start = timestampComponents(
                mins: ns.substring(with: match.range(at: 1)),
                secs: ns.substring(with: match.range(at: 2)),
                frac: match.range(at: 3).location != NSNotFound
                    ? ns.substring(with: match.range(at: 3))
                    : "0"
            )
            let contentStart = match.range.location + match.range.length
            let contentEnd = index + 1 < matches.count
                ? matches[index + 1].range.location
                : ns.length
            guard contentEnd >= contentStart else { continue }
            let wordText = ns.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            let endTime: TimeInterval? = index + 1 < matches.count
                ? timestampComponents(
                    mins: ns.substring(with: matches[index + 1].range(at: 1)),
                    secs: ns.substring(with: matches[index + 1].range(at: 2)),
                    frac: matches[index + 1].range(at: 3).location != NSNotFound
                        ? ns.substring(with: matches[index + 1].range(at: 3))
                        : "0"
                )
                : nil
            words.append(LyricWord(text: wordText, startTime: start, endTime: endTime))
            plain += wordText
        }
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? text : plain, words)
    }

    // MARK: - YRC

    private static func parseYrcBracketLine(_ line: String) -> LyricLine? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return nil }
        let timing = String(line[line.index(after: line.startIndex)..<close])
        let parts = timing.split(separator: ",")
        guard parts.count >= 2,
              let startMs = Double(parts[0]) else { return nil }

        let content = String(line[line.index(after: close)...])
        let words = parseYrcWords(in: content)
        let start = startMs / 1000
        let plain = words.map(\.text).joined()
        if words.count >= 2, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricLine(text: plain, startTime: start, words: words)
        }
        let text = plain.isEmpty ? content : plain
        return LyricLine(text: text, startTime: start)
    }

    private static func parseYrcJSONLine(_ line: String) -> LyricLine? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = jsonDouble(obj["t"]),
              let chunks = obj["c"] as? [[String: Any]] else { return nil }

        var words: [LyricWord] = []
        var plain = ""
        for chunk in chunks {
            let tx = chunk["tx"] as? String ?? ""
            guard !tx.isEmpty else { continue }
            var start = t / 1000
            var end: TimeInterval?
            if let (off, dur) = jsonDoublePair(chunk["tr"]) {
                start = (t + off) / 1000
                end = start + dur / 1000
            }
            words.append(LyricWord(text: tx, startTime: start, endTime: end))
            plain += tx
        }
        guard !plain.isEmpty else { return nil }
        return LyricLine(
            text: plain,
            startTime: t / 1000,
            words: words.count >= 2 ? words : nil
        )
    }

    private static func parseYrcWords(in content: String) -> [LyricWord] {
        // (startMs,durMs,0)word — word runs until the next '(' or end.
        let pattern = #"\((\d+),(\d+),-?\d+\)([^(]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match -> LyricWord? in
            guard let startMs = Double(ns.substring(with: match.range(at: 1))),
                  let durMs = Double(ns.substring(with: match.range(at: 2))) else { return nil }
            let text = ns.substring(with: match.range(at: 3))
            guard !text.isEmpty else { return nil }
            let start = startMs / 1000
            return LyricWord(text: text, startTime: start, endTime: start + durMs / 1000)
        }
    }

    // MARK: - Formatting helpers

    static func formatLrcTimestamp(_ t: TimeInterval) -> String {
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        let centis = Int((t - floor(t)) * 100)
        return String(format: "[%02d:%02d.%02d]", minutes, seconds, centis)
    }

    static func formatEnhancedWordTag(_ t: TimeInterval) -> String {
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        let centis = Int((t - floor(t)) * 100)
        return String(format: "<%02d:%02d.%02d>", minutes, seconds, centis)
    }

    private static func timestampComponents(mins: String, secs: String, frac: String) -> TimeInterval {
        let m = Int(mins) ?? 0
        let s = Int(secs) ?? 0
        let f = Double("0.\(frac)") ?? 0
        return TimeInterval(m * 60 + s) + f
    }

    private static func optionalNonEmpty(_ lines: [LyricLine]) -> [LyricLine]? {
        lines.isEmpty ? nil : lines
    }

    /// JSONSerialization may box whole numbers as Int/NSNumber.
    private static func jsonDouble(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let i as Int64: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    private static func jsonDoublePair(_ value: Any?) -> (Double, Double)? {
        guard let arr = value as? [Any], arr.count >= 2,
              let a = jsonDouble(arr[0]), let b = jsonDouble(arr[1]) else { return nil }
        return (a, b)
    }
}
