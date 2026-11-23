//
//  SimpMusicProvider.swift
//  Trop
//
//  Created by 686udjie on 22/11/2026.
//

import Foundation

struct SimpMusicProvider: LyricsProvider {
    let id = "simpmusic"
    let name = "SimpMusic"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        guard let videoId = query.videoId, !videoId.isEmpty,
              let url = URL(string: "https://api-lyrics.simpmusic.org/v1/\(videoId)") else { throw LyricsError.notFound }
        var request = URLRequest(url: url)
        request.setValue("SimpMusicLyrics/1.0", forHTTPHeaderField: "User-Agent")
        let json = try await LyricsHTTP.getJSON(request)
        guard (json["type"] as? String) == "success",
              let data = json["data"] as? [[String: Any]] else { throw LyricsError.notFound }
        let candidates = data.compactMap { item -> (String, Int)? in
            // `syncedLyrics` is clean line-level LRC. `richSyncLyrics` adds
            // inline <mm:ss.xx> word tags; use it only when the plain synced
            // variant is missing (the parser strips the word tags).
            let raw = [item["syncedLyrics"], item["richSyncLyrics"]]
                .compactMap { $0 as? String }
                .first { !$0.isEmpty }
            guard let raw else { return nil }
            return (raw, item["durationSeconds"] as? Int ?? 0)
        }
        guard let best = candidates.min(by: { lhs, rhs in
            abs(lhs.1 - (query.durationSeconds ?? 0)) < abs(rhs.1 - (query.durationSeconds ?? 0))
        }) else { throw LyricsError.notFound }
        let lines = LyricsParsing.parseLrc(best.0)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }
}
