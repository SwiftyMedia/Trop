//
//  NeteaseProvider.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

// https://github.com/spicetify/cli/blob/main/CustomApps/lyrics-plus/ProviderNetease.js

import Foundation

struct NeteaseProvider: LyricsProvider {
    let id = "netease"
    let name = "Netease"

    private let searchURL = "https://music.xianqiao.wang/neteaseapiv2/search"
    private let lyricURL = "https://music.xianqiao.wang/neteaseapiv2/lyric"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        let cleanTitle = normalize(query.title)
        let keyword = "\(cleanTitle) \(query.artist)"
        guard var components = URLComponents(string: searchURL) else { throw LyricsError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "keywords", value: keyword)
        ]
        guard let url = components.url else { throw LyricsError.invalidURL }

        let json = try await LyricsHTTP.getJSON(URLRequest(url: url))
        guard let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              !songs.isEmpty else {
            throw LyricsError.notFound
        }

        // Score every candidate and pick the best
        let expectedAlbum = normalize(query.album ?? "")
        let dur = Int(query.duration * 1000)
        let queryArtist = normalize(query.artist)

        var bestIndex = 0
        var bestScore = -Double.infinity
        for (i, song) in songs.enumerated() {
            let name = normalize(songName(song))
            let artists = (song["artists"] as? [[String: Any]] ?? [])
                .compactMap { ($0["name"] as? String).map(normalize) }
            let album = normalize(albumName(song))
            let sdur = songDuration(song)

            var score: Double = 0
            if name == cleanTitle {
                score += 100
            } else if name.contains(cleanTitle) || cleanTitle.contains(name) {
                score += 60
            } else {
                score -= 30
            }

            if !queryArtist.isEmpty,
               artists.contains(where: { $0.contains(queryArtist) || queryArtist.contains($0) }) {
                score += 80
            } else if !queryArtist.isEmpty {
                score -= 20
            }

            if !expectedAlbum.isEmpty, album == expectedAlbum { score += 40 }

            if dur > 0, sdur > 0 {
                score += max(0, 30 - Double(abs(sdur - dur)) / 1000)
            }

            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }

        // Reject weak matches
        guard bestScore > 0, let songId = songs[bestIndex]["id"] else {
            throw LyricsError.notFound
        }
        return try await fetchLyrics(songId: "\(songId)")
    }

    private func fetchLyrics(songId: String) async throws -> [LyricLine] {
        guard var components = URLComponents(string: lyricURL) else { throw LyricsError.invalidURL }
        components.queryItems = [URLQueryItem(name: "id", value: songId)]
        guard let url = components.url else { throw LyricsError.invalidURL }

        let json = try await LyricsHTTP.getJSON(URLRequest(url: url))

        // Word-timed YRC when the API provides it
        if let yrc = json["yrc"] as? [String: Any],
           let lyric = yrc["lyric"] as? String,
           !lyric.isEmpty {
            let lines = LyricsParsing.parseYrc(lyric)
            if !lines.isEmpty { return lines }
        }

        // Line-synced LRC fallback
        if let lrc = json["lrc"] as? [String: Any],
           let lyric = lrc["lyric"] as? String,
           !lyric.isEmpty {
            let lines = LyricsParsing.parseLrc(lyric)
            if !lines.isEmpty { return lines }
        }

        // Translated / plain lyrics fallback
        if let tlyric = json["tlyric"] as? [String: Any],
           let lyric = tlyric["lyric"] as? String,
           !lyric.isEmpty {
            let lines = LyricsParsing.parseLrc(lyric)
            if !lines.isEmpty { return lines }
        }

        throw LyricsError.notFound
    }

    // MARK: - Helpers

    private func songName(_ song: [String: Any]) -> String {
        song["name"] as? String ?? ""
    }

    private func albumName(_ song: [String: Any]) -> String {
        (song["album"] as? [String: Any])?["name"] as? String ?? ""
    }

    private func songDuration(_ song: [String: Any]) -> Int {
        song["duration"] as? Int ?? 0
    }

    /// normalize: lowercase, trim, strip common extra info
    private func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\(.*?\)\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[.*?\]\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
