//
//  LyricsHTTP.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import Foundation

/// Shared request boilerplate for lyrics providers: perform the request,
/// require HTTP 200 (anything else is `.notFound`), and decode the body.
/// Preserves each provider's exact error contract — headers, query building
/// and response interpretation stay per-provider.
enum LyricsHTTP {
    /// Cookie-free session. `URLSession.shared` persists cookies across every
    /// provider; Netease in particular starts returning unrelated results once
    /// its cookies are stored (verified: request 1 correct, request 2+ wrong).
    static let noCookies: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// GETs `request`, throwing `.notFound` unless the status is exactly 200.
    static func get(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LyricsError.notFound
        }
        return data
    }

    /// `get` + JSON dictionary decode, throwing `.decodingFailed` on bad JSON.
    static func getJSON(_ request: URLRequest, session: URLSession = .shared) async throws -> [String: Any] {
        let data = try await get(request, session: session)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.decodingFailed
        }
        return json
    }

    /// `get` + `Decodable` decode, throwing `.decodingFailed` on bad JSON.
    static func decoded<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let data = try await get(request)
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw LyricsError.decodingFailed
        }
        return decoded
    }
}

/// Shared plain-text line splitting for lyrics providers.
enum LyricsText {
    /// Splits on newlines, trims, drops empties — untimed lines.
    static func plainLines(_ s: String) -> [LyricLine] {
        s.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(text: $0, startTime: nil) }
    }
}
