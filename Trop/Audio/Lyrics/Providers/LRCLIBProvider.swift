//
//  LRCLIBProvider.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import Foundation

struct LRCLIBProvider: LyricsProvider {
    let id = "lrclib"
    let name = "LRCLIB"

    private let baseURL = "https://lrclib.net/api"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        var candidates = try await search(query: query, title: query.title, album: query.album)
        if candidates == nil {
            candidates = try await search(query: query, title: titleWithoutFeatures(query.title), album: nil)
        }
        guard let best = candidates?.first else { throw LyricsError.notFound }

        if let synced = best.syncedLyrics, !synced.isEmpty {
            let lines = LyricsParsing.parseLrc(synced)
            if !lines.isEmpty { return lines }
        }
        if let plain = best.plainLyrics, !plain.isEmpty {
            let lines = LyricsText.plainLines(plain)
            if !lines.isEmpty { return lines }
        }

        throw LyricsError.notFound
    }

    private func search(query: LyricsQuery, title: String, album: String?) async throws -> [Candidate]? {
        guard var components = URLComponents(string: "\(baseURL)/search") else { throw LyricsError.invalidURL }
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: query.artist)]
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = query.durationSeconds { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        components.queryItems = items
        guard let url = components.url else { throw LyricsError.invalidURL }
        let data = try await LyricsHTTP.get(URLRequest(url: url))
        let candidates = try JSONDecoder().decode([Candidate].self, from: data)
            .filter { !$0.instrumental && ($0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false) }
            .filter { LyricsMatching.titleMatches(query.title, $0.name) }
            .filter { LyricsMatching.artistMatches(query.artist, $0.artistName) }
            .filter { LyricsMatching.durationMatches(query.durationSeconds, $0.duration) }
            .sorted {
                let lhsExact = LyricsMatching.normalize($0.name) == LyricsMatching.normalize(query.title)
                let rhsExact = LyricsMatching.normalize($1.name) == LyricsMatching.normalize(query.title)
                if lhsExact != rhsExact { return lhsExact }
                let lhsSynced = $0.syncedLyrics?.isEmpty == false
                let rhsSynced = $1.syncedLyrics?.isEmpty == false
                if lhsSynced != rhsSynced { return lhsSynced }
                return abs($0.duration - Double(query.durationSeconds ?? 0)) < abs($1.duration - Double(query.durationSeconds ?? 0))
            }
        return candidates.isEmpty ? nil : candidates
    }

    private func titleWithoutFeatures(_ title: String) -> String {
        title.replacingOccurrences(of: #"(?i)\s*[\[(].*?(?:\]|\))|\s+\b(?:feat\.?|ft\.?|featuring)\b.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Candidate: Decodable {
        let name: String
        let artistName: String
        let albumName: String?
        let duration: Double
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }
}

enum LyricsError: Error, LocalizedError {
    case invalidURL
    case notFound
    case decodingFailed
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid lyrics request URL"
        case .notFound: return "Lyrics not found"
        case .decodingFailed: return "Failed to decode lyrics response"
        case .requestFailed(let code): return "Lyrics request failed (HTTP \(code))"
        }
    }
}
