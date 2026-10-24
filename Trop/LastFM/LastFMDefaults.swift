//
//  LastFMDefaults.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation

enum LastFMDefaults {
    // API credentials come from the local Xcode environment in debug builds
    // or Info.plist in release builds.
    static var apiKey: String {
        if let env = ProcessInfo.processInfo.environment["LASTFM_API_KEY"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "LASTFM_API_KEY") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    static var secret: String {
        if let env = ProcessInfo.processInfo.environment["LASTFM_SECRET"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "LASTFM_SECRET") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    static var isConfigured: Bool { !apiKey.isEmpty && !secret.isEmpty }

    static let baseUrl = "https://ws.audioscrobbler.com/2.0/"
    static let authUrlBase = "https://www.last.fm/api/auth/"

    static func authUrl(token: String) -> String {
        "\(authUrlBase)?api_key=\(apiKey)&token=\(token)"
    }

    // Scrobble defaults (mirrors Metrolist)
    static let defaultScrobbleDelayPercent: Float = 0.5
    static let defaultScrobbleMinDuration: Int = 30
    static let defaultScrobbleDelaySeconds: Int = 180

    // UserDefaults keys (keep compatible with Metrolist naming)
    static let sessionKeyKey = "lastfmSession"
    static let usernameKey = "lastfmUsername"
    static let scrobblingEnabledKey = "lastfmScrobblingEnable"
    static let useNowPlayingKey = "lastfmUseNowPlaying"
    static let useSendLikesKey = "lastfmUseSendLikes"
    static let scrobbleDelayPercentKey = "scrobbleDelayPercent"
    static let scrobbleMinDurationKey = "scrobbleMinSongDuration"
    static let scrobbleDelaySecondsKey = "scrobbleDelaySeconds"
}
