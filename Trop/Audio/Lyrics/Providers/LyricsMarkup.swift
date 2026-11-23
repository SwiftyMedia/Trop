//
//  LyricsMarkup.swift
//  Trop
//
//  Created by 686udjie on 22/11/2026.
//

import Foundation

/// Small parser for the TTML returned by BetterLyrics, Unison and lrc.red.
/// It intentionally keeps only the fields the iOS lyrics view needs.
enum LyricsMarkup {
    static func parse(_ raw: String) -> [LyricLine] {
        let pattern = #"(?is)<p\b([^>]*)>(.*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(raw.startIndex..., in: raw)
        let lines: [LyricLine] = regex.matches(in: raw, range: range).compactMap { match -> LyricLine? in
            guard let attributesRange = Range(match.range(at: 1), in: raw),
                  let textRange = Range(match.range(at: 2), in: raw) else { return nil }
            let attributes = String(raw[attributesRange])
            let text = stripTags(String(raw[textRange])).decodingHTMLEntities().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = attribute("begin", in: attributes).flatMap(parseTime)
            return LyricLine(text: text, startTime: start)
        }
        return lines
    }

    static func parseAny(_ raw: String) -> [LyricLine] {
        let looksLikeTTML = raw.range(of: "<tt", options: .caseInsensitive) != nil
            || raw.range(of: "<p", options: .caseInsensitive) != nil
        if looksLikeTTML {
            let ttml = parse(raw)
            if !ttml.isEmpty { return ttml }
        }
        return LyricsParsing.parseStoredText(raw)
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        // Raw-string interpolation needs `\#(...)`; `#(...)` would be literal.
        let pattern = #"(?i)\b\#(name)\s*=\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
              let valueRange = Range(match.range(at: 1), in: attributes) else { return nil }
        return String(attributes[valueRange])
    }

    private static func parseTime(_ value: String) -> TimeInterval? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("ms") { return Double(value.dropLast(2)).map { $0 / 1000 } }
        if value.hasSuffix("s") { return Double(value.dropLast()).map { $0 } }
        let pieces = value.split(separator: ":")
        switch pieces.count {
        case 3:
            // TTML timestamps are `hh:mm:ss.fff`, not `mm:ss.fff`.
            guard let hours = Double(pieces[0]),
                  let minutes = Double(pieces[1]),
                  let seconds = Double(pieces[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            guard let minutes = Double(pieces[0]), let seconds = Double(pieces[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return Double(value)
        }
    }

    private static func stripTags(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }
}
