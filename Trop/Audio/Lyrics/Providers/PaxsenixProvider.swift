//
//  PaxsenixProvider.swift
//  Trop
//
//  Created by 686udjie on 22/11/2026.
//

import Foundation

struct PaxsenixProvider: LyricsProvider {
    let id = "paxsenix"
    let name = "Paxsenix"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        let token = try await appleMusicToken()
        guard var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/us/search") else { throw LyricsError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(query.title) \(query.artist)"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "format[resources]", value: "map"),
            URLQueryItem(name: "include[songs]", value: "artists"),
            URLQueryItem(name: "extend", value: "artistUrl")
        ]
        guard let url = components.url else { throw LyricsError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let json = try await LyricsHTTP.getJSON(request)
        guard let results = json["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let data = songs["data"] as? [[String: Any]],
              let resources = json["resources"] as? [String: Any],
              let resourceSongs = resources["songs"] as? [String: Any] else { throw LyricsError.notFound }

        for item in data {
            guard let id = item["id"] as? String,
                  let detail = resourceSongs[id] as? [String: Any],
                  let attributes = detail["attributes"] as? [String: Any],
                  let title = attributes["name"] as? String,
                  let artist = attributes["artistName"] as? String,
                  LyricsMatching.titleMatches(query.title, title),
                  LyricsMatching.artistMatches(query.artist, artist) else { continue }

            // Paxsenix's own proxy is frequently behind a Cloudflare
            // challenge, so keep it as the first attempt and fall back to the
            // canonical Apple Music metadata resolved above.
            if let lines = try? await paxsenixLyrics(id: id), !lines.isEmpty {
                return lines
            }
            if let isrc = attributes["isrc"] as? String,
               let lines = try? await lrcRedLyrics(isrc: isrc), !lines.isEmpty {
                return lines
            }
            let millis = attributes["durationInMillis"] as? Int
            if let lines = try? await betterLyrics(
                title: title,
                artist: artist,
                album: attributes["albumName"] as? String,
                duration: millis.map { $0 / 1000 }
            ), !lines.isEmpty {
                return lines
            }
        }
        throw LyricsError.notFound
    }

    private func paxsenixLyrics(id: String) async throws -> [LyricLine] {
        var components = URLComponents(string: "https://lyrics.paxsenix.org/apple-music/lyrics")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "ttml", value: "true")
        ]
        guard let url = components.url else { throw LyricsError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Metrolist", forHTTPHeaderField: "User-Agent")
        let data = try await LyricsHTTP.get(request)

        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") {
                let lines = LyricsMarkup.parseAny(text)
                if !lines.isEmpty { return lines }
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in ["content", "ttml", "lyrics", "data", "plain", "elrc"] {
                    if let raw = json[key] as? String {
                        let lines = LyricsMarkup.parseAny(raw)
                        if !lines.isEmpty { return lines }
                    }
                }
            }
        }
        throw LyricsError.notFound
    }

    private func lrcRedLyrics(isrc: String) async throws -> [LyricLine] {
        guard !isrc.isEmpty, let url = URL(string: "https://lrc.red/s/\(isrc).ttml") else {
            throw LyricsError.invalidURL
        }
        let raw = try await LyricsHTTP.get(URLRequest(url: url))
        guard let text = String(data: raw, encoding: .utf8) else { throw LyricsError.decodingFailed }
        let lines = LyricsMarkup.parseAny(text)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    private func betterLyrics(title: String, artist: String, album: String?, duration: Int?) async throws -> [LyricLine] {
        guard var components = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics") else {
            throw LyricsError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "s", value: title),
            URLQueryItem(name: "a", value: artist),
            URLQueryItem(name: "al", value: album),
            URLQueryItem(name: "d", value: duration.map(String.init))
        ].filter { $0.value != nil }
        guard let url = components.url else { throw LyricsError.invalidURL }
        let json = try await LyricsHTTP.getJSON(URLRequest(url: url))
        guard let ttml = json["ttml"] as? String else { throw LyricsError.notFound }
        let lines = LyricsMarkup.parseAny(ttml)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    private func appleMusicToken() async throws -> String {
        guard let pageURL = URL(string: "https://beta.music.apple.com") else { throw LyricsError.invalidURL }
        let page = try await String(data: LyricsHTTP.get(URLRequest(url: pageURL)), encoding: .utf8).orThrow(LyricsError.decodingFailed)
        guard let script = page.range(of: #"/assets/index~[^/]+\.js"#, options: .regularExpression) else { throw LyricsError.notFound }
        let path = String(page[script])
        guard let jsURL = URL(string: "https://beta.music.apple.com\(path)") else { throw LyricsError.invalidURL }
        let js = try await String(data: LyricsHTTP.get(URLRequest(url: jsURL)), encoding: .utf8).orThrow(LyricsError.decodingFailed)
        guard let token = js.range(
            of: #"eyJ[A-Za-z0-9\-_=]+\.[A-Za-z0-9\-_=]+\.[A-Za-z0-9\-_=]+"#,
            options: .regularExpression
        ) else { throw LyricsError.notFound }
        return String(js[token])
    }
}

private extension Optional where Wrapped == String {
    func orThrow(_ error: LyricsError) throws -> String {
        guard let self else { throw error }
        return self
    }
}
