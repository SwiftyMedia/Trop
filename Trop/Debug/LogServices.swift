//
//  LogServices.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

extension Log {
    static var discord: AppLogger { make("DiscordSvc", file: "services") }
    static var lastfm: AppLogger { make("LastFM", file: "services") }
    static var lyrics: AppLogger { make("Lyrics", file: "services", redact: false) }
}
