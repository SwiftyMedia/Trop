//
//  LogStream.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

extension Log {
    static var player: AppLogger { make("Player", file: "stream", redact: false) }
    static var mpv: AppLogger { make("MPV", file: "stream", writesToDisk: false, redact: false) }
    static var sponsorBlock: AppLogger { make("SponsorBlock", file: "stream", redact: false) }
    static var nowPlaying: AppLogger { make("NowPlaying", file: "stream") }
    static var playbackState: AppLogger { make("PlaybackState", file: "stream") }
    static var registerPlayback: AppLogger { make("RegisterPlayback", file: "stream") }
}
