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

    private let searchURL = "https://music.163.com/api/search/get"
    private let lyricURL = "https://music.163.com/api/song/lyric"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        let cleanTitle = LyricsMatching.normalize(query.title)
        let keyword = "\(cleanTitle) \(query.artist)"
        guard var components = URLComponents(string: searchURL) else { throw LyricsError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "s", value: keyword),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "type", value: "1")
        ]
        guard let url = components.url else { throw LyricsError.invalidURL }

        let json = try await LyricsHTTP.getJSON(request(url), session: LyricsHTTP.noCookies)
        guard let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              !songs.isEmpty else {
            throw LyricsError.notFound
        }

        // Score every candidate and pick the best
        let expectedAlbum = LyricsMatching.normalize(query.album ?? "")
        let dur = query.durationSeconds.map { $0 * 1000 } ?? 0
        let queryArtist = LyricsMatching.normalize(query.artist)

        var bestIndex = 0
        var bestScore = -Double.infinity
        for (i, song) in songs.enumerated() {
            let name = LyricsMatching.normalize(songName(song))
            let artists = (song["artists"] as? [[String: Any]] ?? [])
                .compactMap { ($0["name"] as? String).map(LyricsMatching.normalize) }
            let album = LyricsMatching.normalize(albumName(song))
            let sdur = songDuration(song)

            var score: Double = 0
            if name == LyricsMatching.normalize(cleanTitle) {
                score += 100
            } else if name.contains(cleanTitle) || cleanTitle.contains(name) {
                score += 60
            } else {
                score -= 30
            }

            if !queryArtist.isEmpty,
               artists.contains(where: { LyricsMatching.artistMatches(query.artist, $0) }) {
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
        guard bestScore >= 80, let songId = songs[bestIndex]["id"] else {
            throw LyricsError.notFound
        }
        return try await fetchLyrics(songId: "\(songId)")
    }

    private func fetchLyrics(songId: String) async throws -> [LyricLine] {
        guard var components = URLComponents(string: lyricURL) else { throw LyricsError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        guard let url = components.url else { throw LyricsError.invalidURL }

        let json = try await LyricsHTTP.getJSON(request(url), session: LyricsHTTP.noCookies)

        // Synced lyrics (LRC) take priority
        if let lrc = json["lrc"] as? [String: Any],
           let lyric = lrc["lyric"] as? String,
           !lyric.isEmpty {
            let lines = cleaned(LyricsParsing.parseLrc(lyric))
            if !lines.isEmpty { return lines }
        }

        // Plain lyrics fallback
        if let tlyric = json["tlyric"] as? [String: Any],
           let lyric = tlyric["lyric"] as? String,
           !lyric.isEmpty {
            let lines = cleaned(LyricsParsing.parseLrc(lyric))
            if !lines.isEmpty { return lines }
        }

        throw LyricsError.notFound
    }

    /// Netease prepends credit lines (`作词 : …`, `作曲 : …`) and marks
    /// instrumental tracks with a placeholder. Drop those so the view matches
    /// the other providers.
    private static let creditPrefixes = [
        "作词", "作曲", "编曲", "制作人", "监制", "出品", "发行", "原曲",
        "混音", "母带", "录音", "和声", "吉他", "贝斯", "键盘", "弦乐",
        "op", "sp", "lyrics", "composer", "arranger", "producer", "mixed",
        "mastered", "written"
    ]

    private func cleaned(_ lines: [LyricLine]) -> [LyricLine] {
        lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            if text.contains("暂无歌词") || text.contains("纯音乐") { return false }
            let lower = text.lowercased()
            for prefix in Self.creditPrefixes where lower.hasPrefix(prefix) {
                let rest = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(":") || rest.hasPrefix("：") { return false }
            }
            return true
        }
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

    /// Netease's public web API rejects requests without a browser referer.
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        return request
    }

}
