//
//  DiscordDefaults.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation

enum DiscordDefaults {
    static let appId: String = "1563551993652445258"

    static let oauthToken = "https://discord.com/api/v10/oauth2/token"

    // Optional local-only support for applications that require confidential
    // token exchange. Native builds should normally use PKCE without this.
    static var clientSecret: String {
        if let env = ProcessInfo.processInfo.environment["DISCORD_CLIENT_SECRET"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "DISCORD_CLIENT_SECRET") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
    // Activity / presence defaults
    static let youtubeWatchUrl = "https://music.youtube.com/watch?v="
    static let button1Label = "Listen on YouTube Music"
    static let button1UrlTemplate = "https://music.youtube.com/watch?v={song.id}"
    static let button2Label = "Visit Trop"
    static let button2Url = "https://github.com/SwiftyMedia/Trop"
    static let stateTemplate = "{artist.name}"
    static let detailsTemplate = "{song.name}"
    static let activityType = "2"
    static let activityName = ""
    static let userStatus = "online"
    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"

}
