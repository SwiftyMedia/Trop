//
//  MusixmatchProvider.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

// https://github.com/spicetify/cli/blob/main/CustomApps/lyrics-plus/ProviderMusixmatch.js

import Foundation

struct MusixmatchProvider: LyricsProvider {
    let id = "musixmatch"
    let name = "Musixmatch"

    private let baseURL = "https://apic-appmobile.musixmatch.com/ws/1.1/macro.subtitles.get"
    private let tokenURL = "https://apic-appmobile.musixmatch.com/ws/1.1/token.get?app_id=mac-ios-v2.0&"

    // Guest token is fetched once and reused across requests.
    private static var guestToken: String?

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        let token = try await fetchToken()
        var components = URLComponents(string: baseURL)!
        let dur = Int(query.duration)
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynched"),
            URLQueryItem(name: "subtitle_format", value: "mxm"),
            URLQueryItem(name: "app_id", value: "mac-ios-v2.0"),
            URLQueryItem(name: "q_track", value: query.title),
            URLQueryItem(name: "q_artist", value: query.artist),
            URLQueryItem(name: "q_artists", value: query.artist),
            URLQueryItem(name: "q_album", value: query.album ?? ""),
            URLQueryItem(name: "q_duration", value: String(dur)),
            URLQueryItem(name: "f_subtitle_length", value: String(dur)),
            URLQueryItem(name: "usertoken", value: token),
            URLQueryItem(name: "part", value: "track_lyrics_translation_status,track_structure,track_performer_tagging")
        ]

        guard let url = components.url else { throw LyricsError.invalidURL }
        var request = URLRequest(url: url)
        applyHeaders(to: &request)

        let json = try await LyricsHTTP.getJSON(request)
        return try parse(json)
    }

    // MARK: - Token

    private func fetchToken() async throws -> String {
        if let cached = Self.guestToken { return cached }
        guard let url = URL(string: tokenURL) else { throw LyricsError.invalidURL }
        var request = URLRequest(url: url)
        applyHeaders(to: &request)

        let json = try await LyricsHTTP.getJSON(request)
        guard let message = json["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let token = body["user_token"] as? String, !token.isEmpty else {
            throw LyricsError.notFound
        }
        Self.guestToken = token
        return token
    }

    // MARK: - Parsing

    private func parse(_ json: [String: Any]) throws -> [LyricLine] {
        guard let message = json["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let macro = body["macro_calls"] as? [String: Any] else {
            throw LyricsError.notFound
        }

        // Matcher must ==
        guard let matcher = macro["matcher.track.get"] as? [String: Any],
              let mMessage = matcher["message"] as? [String: Any],
              let mHeader = mMessage["header"] as? [String: Any],
              (mHeader["status_code"] as? Int) == 200 else {
            throw LyricsError.notFound
        }

        let mBody = mMessage["body"] as? [String: Any] ?? [:]
        let track = mBody["track"] as? [String: Any] ?? [:]
        if track["instrumental"] as? Bool == true {
            return [LyricLine(text: "♪ Instrumental ♪", startTime: nil)]
        }

        // Restricted lyrics cannot be shown
        if let lyricsCall = macro["track.lyrics.get"] as? [String: Any],
           let lMessage = lyricsCall["message"] as? [String: Any],
           let lBody = lMessage["body"] as? [String: Any],
           let lyrics = lBody["lyrics"] as? [String: Any],
           (lyrics["restricted"] as? Bool) == true {
            throw LyricsError.notFound
        }

        // Word-synced richsync (preferred when namespace=lyrics_richsynched)
        if let richLines = parseRichsync(from: macro), !richLines.isEmpty {
            return richLines
        }

        // Line-synced subtitles
        if let subsCall = macro["track.subtitles.get"] as? [String: Any],
           let sMessage = subsCall["message"] as? [String: Any],
           let sBody = sMessage["body"] as? [String: Any],
           let subList = sBody["subtitle_list"] as? [[String: Any]],
           let first = subList.first,
           let subtitle = first["subtitle"] as? [String: Any],
           let bodyStr = subtitle["subtitle_body"] as? String,
           let data = bodyStr.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let lines = arr.compactMap { item -> LyricLine? in
                guard let text = item["text"] as? String,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let time = (item["time"] as? [String: Any])?["total"] as? Double ?? 0
                return LyricLine(text: text, startTime: time > 0 ? time : nil)
            }
            if !lines.isEmpty { return lines }
        }

        // Unsynced
        if let lyricsCall = macro["track.lyrics.get"] as? [String: Any],
           let lMessage = lyricsCall["message"] as? [String: Any],
           let lBody = lMessage["body"] as? [String: Any],
           let lyrics = lBody["lyrics"] as? [String: Any],
           let bodyStr = lyrics["lyrics_body"] as? String {
            let lines = LyricsText.plainLines(bodyStr)
            if !lines.isEmpty { return lines }
        }

        throw LyricsError.notFound
    }

    /// Parses `track.richsync.get` — each line has `ts`/`te` and word chunks
    /// `{c, o}` where absolute word time = `ts + o`.
    private func parseRichsync(from macro: [String: Any]) -> [LyricLine]? {
        guard let richCall = macro["track.richsync.get"] as? [String: Any],
              let rMessage = richCall["message"] as? [String: Any],
              let rHeader = rMessage["header"] as? [String: Any],
              (rHeader["status_code"] as? Int) == 200,
              let rBody = rMessage["body"] as? [String: Any],
              let richsync = rBody["richsync"] as? [String: Any],
              let bodyStr = richsync["richsync_body"] as? String,
              let data = bodyStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let lines: [LyricLine] = arr.compactMap { item in
            // ts=0 is valid (first line); do not coerce to nil or serialize/seek drop words.
            let ts = Self.jsonDouble(item["ts"]) ?? 0
            let te = Self.jsonDouble(item["te"])
            let lineText = (item["x"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let chunks = item["l"] as? [[String: Any]] ?? []

            var words: [LyricWord] = []
            for (index, chunk) in chunks.enumerated() {
                let c = chunk["c"] as? String ?? ""
                // Skip empty chunks; keep whitespace-only chunks so spacing stays correct.
                guard !c.isEmpty else { continue }
                let offset = Self.jsonDouble(chunk["o"]) ?? 0
                let start = ts + offset
                let end: TimeInterval?
                if index + 1 < chunks.count,
                   let nextOffset = Self.jsonDouble(chunks[index + 1]["o"]) {
                    end = ts + nextOffset
                } else {
                    end = te
                }
                words.append(LyricWord(text: c, startTime: start, endTime: end))
            }

            let plain = lineText.isEmpty ? words.map(\.text).joined() : lineText
            guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let wordList = words.count >= 2 ? words : nil
            return LyricLine(text: plain, startTime: ts, words: wordList)
        }
        return lines.isEmpty ? nil : lines
    }

    /// JSONSerialization may surface whole numbers as Int/NSNumber.
    private static func jsonDouble(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let i as Int64: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    // MARK: - Headers

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("apic-appmobile.musixmatch.com", forHTTPHeaderField: "Host")
        request.setValue("apic-appmobile.musixmatch.com", forHTTPHeaderField: "authority")
        request.setValue("x-mxm-token-guid=", forHTTPHeaderField: "X-Cookie")
        request.setValue("10.1.1", forHTTPHeaderField: "x-mxm-app-version")
        request.setValue("Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0", forHTTPHeaderField: "X-User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }
}
