//
//  DebugLogStore.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

import Foundation

/// Stores one rotating file per debug category
final class DebugLogStore {
    static let shared = DebugLogStore()

    private let queue = DispatchQueue(label: "com.686udjie.Trop.DebugLogStore")
    private let maxBytes = 1_000_000

    var directoryURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Debug", isDirectory: true)
    }

    private init() {}

    func append(category: String, level: String, message: String) {
        queue.async { [weak self] in
            guard let self, let directory = self.directoryURL else { return }
            let fileURL = directory.appendingPathComponent(self.fileName(for: category))
            let stamp = Self.formatter.string(from: Date())
            let line = "\(stamp) [\(level)] \(message)\n"

            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                guard let data = line.data(using: .utf8) else { return }

                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attributes[.size] as? Int,
                   size > self.maxBytes {
                    try data.write(to: fileURL, options: .atomic)
                } else if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                // Logging must never interrupt the app
            }
        }
    }

    private func fileName(for category: String) -> String {
        let safe = category.lowercased().map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        return String(safe) + ".log"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
