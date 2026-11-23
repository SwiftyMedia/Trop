//
//  KugouProvider.swift
//  Trop
//
//  Created by 686udjie on 17/07/2026.
//

// https://github.com/MetrolistGroup/Metrolist/blob/main/kugou/src/main/kotlin/com/metrolist/kugou/KuGou.kt

import Foundation

struct KugouProvider: LyricsProvider {
    let id = "kugou"
    let name = "KuGou"

    private let durationTolerance = 8 // seconds

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        let keyword = generateKeyword(title: query.title, artist: query.artist, album: query.album)
        let duration = query.durationSeconds ?? 0

        guard let candidate = try await getLyricsCandidate(keyword: keyword, duration: duration) else {
            throw LyricsError.notFound
        }

        let raw = try await downloadLyrics(id: candidate.id, accessKey: candidate.accesskey)
        let lines = LyricsParsing.parseLrc(raw)
        if lines.isEmpty { throw LyricsError.notFound }
        return lines
    }

    // MARK: - Candidate resolution

    private func getLyricsCandidate(keyword: Keyword, duration: Int) async throws -> SearchLyricsResponse.Candidate? {
        // Try matching by song hash first
        let songs = try await searchSongs(keyword: keyword)
        for song in songs where duration <= 0 || abs(song.duration - duration) <= durationTolerance {
            if let candidate = try await searchLyricsByHash(hash: song.hash).candidates.first {
                return candidate
            }
        }
        // Fallback to keyword search
        let response = try await searchLyricsByKeyword(keyword: keyword, duration: duration)
        guard duration <= 0 || !response.candidates.isEmpty else { return nil }
        return response.candidates.first
    }

    // MARK: - Requests

    private func searchSongs(keyword: Keyword) async throws -> [SearchSongResponse.Info] {
        guard var components = URLComponents(string: "https://mobileservice.kugou.com/api/v3/search/song") else {
            throw LyricsError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "version", value: "9108"),
            URLQueryItem(name: "plat", value: "0"),
            URLQueryItem(name: "pagesize", value: "8"),
            URLQueryItem(name: "showtype", value: "0"),
            URLQueryItem(name: "keyword", value: buildSearchQuery(keyword))
        ]
        guard let url = components.url else { throw LyricsError.invalidURL }

        let decoded: SearchSongResponse = try await LyricsHTTP.decoded(SearchSongResponse.self, URLRequest(url: url))
        return decoded.data.info
    }

    private func searchLyricsByHash(hash: String) async throws -> SearchLyricsResponse {
        guard var components = URLComponents(string: "https://lyrics.kugou.com/search") else {
            throw LyricsError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "hash", value: hash)
        ]
        return try await performLyricsSearch(components)
    }

    private func searchLyricsByKeyword(keyword: Keyword, duration: Int) async throws -> SearchLyricsResponse {
        guard var components = URLComponents(string: "https://lyrics.kugou.com/search") else {
            throw LyricsError.invalidURL
        }
        var items = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: buildSearchQuery(keyword))
        ]
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(duration * 1000)))
        }
        components.queryItems = items
        return try await performLyricsSearch(components)
    }

    private func performLyricsSearch(_ components: URLComponents) async throws -> SearchLyricsResponse {
        guard let url = components.url else { throw LyricsError.invalidURL }
        return try await LyricsHTTP.decoded(SearchLyricsResponse.self, URLRequest(url: url))
    }

    private func downloadLyrics(id: String, accessKey: String) async throws -> String {
        guard var components = URLComponents(string: "https://lyrics.kugou.com/download") else {
            throw LyricsError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "accesskey", value: accessKey)
        ]
        guard let url = components.url else { throw LyricsError.invalidURL }

        let data = try await LyricsHTTP.get(URLRequest(url: url))
        guard let decoded = try? JSONDecoder().decode(DownloadLyricsResponse.self, from: data),
              let decodedData = Data(base64Encoded: decoded.content),
              let text = String(data: decodedData, encoding: .utf8) else {
            throw LyricsError.decodingFailed
        }
        return text
    }

    // MARK: - Helpers

    private func buildSearchQuery(_ keyword: Keyword) -> String {
        var q = keyword.title + " - " + keyword.artist
        if let album = keyword.album, !album.isEmpty {
            q += " " + album
        }
        return q
    }

    private func generateKeyword(title: String, artist: String, album: String?) -> Keyword {
        Keyword(title: normalizeTitle(title), artist: normalizeArtist(artist), album: album)
    }

    private func normalizeTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\(.*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"（.*）"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"「.*」"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"『.*』"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<.*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"《.*》"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"〈.*〉"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"＜.*＞"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeArtist(_ artist: String) -> String {
        artist
            .replacingOccurrences(of: ", ", with: "、")
            .replacingOccurrences(of: " & ", with: "、")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "和", with: "、")
            .replacingOccurrences(of: #"\(.*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"（.*）"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models

private struct Keyword {
    let title: String
    let artist: String
    let album: String?
}

private struct SearchSongResponse: Decodable {
    let data: Data

    struct Data: Decodable {
        let info: [Info]
    }

    struct Info: Decodable {
        let duration: Int
        let hash: String
    }
}

private struct SearchLyricsResponse: Decodable {
    let candidates: [Candidate]

    struct Candidate: Decodable {
        let id: String
        let accesskey: String
    }
}

private struct DownloadLyricsResponse: Decodable {
    let content: String
}
