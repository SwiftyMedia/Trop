//
//  String+App.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import Foundation

extension String {
    /// Nil when empty.
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// True when empty or all whitespace.
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Decodes common HTML entities (named + numeric/hex) into characters.
    func decodingHTMLEntities() -> String {
        var result = self
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, char) in named {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        result = replaceNumericEntities(in: result, pattern: #"&#(\d+);"#, radix: 10)
        result = replaceNumericEntities(in: result, pattern: #"&#x([0-9a-fA-F]+);"#, radix: 16)
        return result
    }
}

private func replaceNumericEntities(in string: String, pattern: String, radix: Int) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
    let matches = regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    var result = string
    for match in matches.reversed() {
        guard let codeRange = Range(match.range(at: 1), in: string),
              let code = UInt32(string[codeRange], radix: radix),
              let scalar = UnicodeScalar(code) else { continue }
        result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
    }
    return result
}
