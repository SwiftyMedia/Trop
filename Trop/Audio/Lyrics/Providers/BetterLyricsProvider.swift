//
//  BetterLyricsProvider.swift
//  Trop
//
//  Created by 686udjie on 22/11/2026.
//

import Foundation

struct BetterLyricsProvider: LyricsProvider {
    let id = "betterlyrics"
    let name = "Better Lyrics"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        guard var components = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics") else { throw LyricsError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "s", value: query.title),
            URLQueryItem(name: "a", value: query.artist),
            URLQueryItem(name: "al", value: query.album),
            URLQueryItem(name: "d", value: query.durationSeconds.map(String.init))
        ].filter { $0.value != nil }
        guard let url = components.url else { throw LyricsError.invalidURL }
        let json = try await LyricsHTTP.getJSON(URLRequest(url: url))
        guard let ttml = json["ttml"] as? String else { throw LyricsError.notFound }
        let lines = LyricsMarkup.parseAny(ttml)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }
}
