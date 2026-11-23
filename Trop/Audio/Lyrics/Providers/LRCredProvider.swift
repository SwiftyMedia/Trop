//
//  LRCredProvider.swift
//  Trop
//
//  Created by 686udjie on 22/11/2026.
//

import Foundation

struct LRCredProvider: LyricsProvider {
    let id = "lrc.red"
    let name = "lrc.red"

    private struct SearchResponse: Decodable { let results: [Result] }
    private struct Result: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let lyricsUrl: String?

        // lrc.red returns snake_case (`track_name`, `artist_name`,
        // `lyricsUrl`); without these keys every candidate decoded as nil and
        // the provider always reported "Lyrics not found".
        enum CodingKeys: String, CodingKey {
            case trackName = "track_name"
            case artistName = "artist_name"
            case duration
            case lyricsUrl
        }
    }

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        guard var components = URLComponents(string: "https://lrc.red/api/v1") else { throw LyricsError.invalidURL }
        components.queryItems = [URLQueryItem(name: "q", value: "\(query.title) \(query.artist)")]
        guard let url = components.url else { throw LyricsError.invalidURL }
        let response = try await LyricsHTTP.decoded(SearchResponse.self, URLRequest(url: url))
        guard let result = response.results.first(where: { candidate in
            guard let title = candidate.trackName, let artist = candidate.artistName else { return false }
            return LyricsMatching.titleMatches(query.title, title)
                && LyricsMatching.artistMatches(query.artist, artist)
                && LyricsMatching.durationMatches(query.durationSeconds, candidate.duration ?? 0)
        }), let lyricsURL = result.lyricsUrl,
              let resolvedURL = URL(string: lyricsURL.hasPrefix("/") ? "https://lrc.red\(lyricsURL)" : lyricsURL) else {
            throw LyricsError.notFound
        }
        let raw = try await LyricsHTTP.get(URLRequest(url: resolvedURL))
        guard let text = String(data: raw, encoding: .utf8) else { throw LyricsError.decodingFailed }
        let lines = LyricsMarkup.parseAny(text)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }
}
