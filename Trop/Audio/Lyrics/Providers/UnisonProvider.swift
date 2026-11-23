//
//  UnisonProvider.swift
//  Trop
//
//  Created by 686udjie on 22/11/2026.
//

import Foundation

struct UnisonProvider: LyricsProvider {
    let id = "unison"
    let name = "Unison"

    private let baseURL = "https://unison.boidu.dev"
    private let maxVariantsToCheck = 8

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        if let videoId = query.videoId, !videoId.isEmpty,
           let lines = try? await lyrics(videoId: videoId), !lines.isEmpty {
            return lines
        }
        var items = [URLQueryItem(name: "song", value: query.title), URLQueryItem(name: "artist", value: query.artist)]
        if let album = query.album { items.append(URLQueryItem(name: "album", value: album)) }
        if let duration = query.durationSeconds { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        return try await lyrics(queryItems: items, validating: query)
    }

    private func lyrics(videoId: String) async throws -> [LyricLine] {
        let data = try await payload([URLQueryItem(name: "v", value: videoId)])
        let lines = parse(data)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        guard !lines.contains(where: { $0.startTime != nil }) else { return lines }

        // Unison ranks submissions by votes, so a plain-text version can
        // outrank a synced one. Prefer a synced variant before accepting
        // lyrics the player cannot follow or seek through.
        if let synced = try? await syncedVariant(videoId: videoId) {
            return synced
        }
        return lines
    }

    /// Metadata lookups are fuzzy, so reject results that clearly belong to a
    /// different song before showing them.
    private func lyrics(queryItems: [URLQueryItem], validating query: LyricsQuery) async throws -> [LyricLine] {
        let data = try await payload(queryItems)
        if let song = data["song"] as? String, !LyricsMatching.titleMatches(query.title, song) {
            throw LyricsError.notFound
        }
        if let artist = data["artist"] as? String, !LyricsMatching.artistMatches(query.artist, artist) {
            throw LyricsError.notFound
        }
        let lines = parse(data)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    /// Variants arrive best-ranked first; returns the first one that parses
    /// into timestamped lines.
    private func syncedVariant(videoId: String) async throws -> [LyricLine] {
        guard let url = URL(string: "\(baseURL)/lyrics/variants/\(videoId)") else {
            throw LyricsError.invalidURL
        }
        let json = try await LyricsHTTP.getJSON(URLRequest(url: url))
        guard (json["success"] as? Bool) == true,
              let variants = json["data"] as? [[String: Any]] else { throw LyricsError.notFound }
        for variant in variants.prefix(maxVariantsToCheck) {
            let lines = parse(variant)
            if lines.contains(where: { $0.startTime != nil }) { return lines }
        }
        throw LyricsError.notFound
    }

    private func payload(_ queryItems: [URLQueryItem]) async throws -> [String: Any] {
        guard var components = URLComponents(string: "\(baseURL)/lyrics") else {
            throw LyricsError.invalidURL
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw LyricsError.invalidURL }
        let json = try await LyricsHTTP.getJSON(URLRequest(url: url))
        guard (json["success"] as? Bool) == true,
              let data = json["data"] as? [String: Any] else { throw LyricsError.notFound }
        return data
    }

    private func parse(_ data: [String: Any]) -> [LyricLine] {
        guard let raw = data["lyrics"] as? String, !raw.isEmpty else { return [] }
        // `parseAny` detects TTML and otherwise falls back to LRC/plain.
        return LyricsMarkup.parseAny(raw)
    }
}
