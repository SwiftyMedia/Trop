//
//  LogSync.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

extension Log {
    static var sync: AppLogger { make("Sync", file: "sync") }
    static var playlistDetail: AppLogger { make("PlaylistDetail", file: "sync") }
    static var addSong: AppLogger { make("AddSong", file: "sync") }
}
