//
//  TropLibraryStore.swift
//  Trop
//
//  Created by 686udjie on 09/10/2026.
//

import Foundation
import GRDB

struct TropLibraryStore: LibrarySyncStore {
    private let db = DatabaseService.shared
}

// MARK: - Library sections

extension TropLibraryStore {
    func applyArtistSync(items: [ParsedArtist]) async throws -> Set<String> {
        let remoteIds = Set(items.map(\.browseId))
        try await db.write { db in
            for item in items {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO artist (id, name, thumbnail_url, bookmarked_at, is_podcast_channel, channel_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [item.browseId, item.name, item.thumbnailUrl,
                                     Date(), false, item.channelId])
            }
            if !remoteIds.isEmpty {
                let placeholders = DatabaseService.placeholders(count: remoteIds.count)
                try db.execute(
                    sql: "UPDATE artist SET bookmarked_at = NULL WHERE bookmarked_at IS NOT NULL AND id NOT IN (\(placeholders))",
                    arguments: StatementArguments(Array(remoteIds))
                )
            }
        }
        return remoteIds
    }

    func applyPlaylistSync(items: [ParsedPlaylist]) async throws -> Set<String> {
        let remoteIds = Set(items.map(\.browseId))
        try await db.write { db in
            for item in items {
                let existing = try PlaylistEntity.fetchOne(db, key: item.browseId)
                let entity = PlaylistEntity(
                    id: item.browseId,
                    browseId: item.browseId,
                    name: item.title,
                    thumbnailUrl: item.thumbnailUrl ?? existing?.thumbnailUrl,
                    isEditable: existing?.isEditable ?? false,
                    bookmarkedAt: existing?.bookmarkedAt ?? Date(),
                    remoteSongCount: item.songCount ?? existing?.remoteSongCount,
                    isAutoSync: true
                )
                try entity.save(db)
            }
            if !remoteIds.isEmpty {
                try db.execute(sql: """
                    DELETE FROM playlist_song_map WHERE playlist_id IN (
                        SELECT id FROM playlist WHERE is_auto_sync = 1 AND browse_id IS NOT NULL
                        AND browse_id NOT IN (\(DatabaseService.placeholders(count: remoteIds.count)))
                    )
                    """, arguments: StatementArguments(Array(remoteIds)))
                try db.execute(sql: """
                    DELETE FROM playlist WHERE is_auto_sync = 1 AND browse_id IS NOT NULL
                    AND browse_id NOT IN (\(DatabaseService.placeholders(count: remoteIds.count)))
                    """, arguments: StatementArguments(Array(remoteIds)))
            }
        }
        return remoteIds
    }

    func applyAlbumSync(items: [ParsedAlbum]) async throws -> Set<String> {
        let remoteIds = Set(items.map(\.browseId))
        try await db.write { db in
            for item in items {
                let existing = try AlbumEntity.fetchOne(db, key: item.browseId)
                let entity = AlbumEntity(
                    id: item.browseId,
                    title: item.title,
                    playlistId: item.playlistId ?? existing?.playlistId,
                    thumbnailUrl: item.thumbnailUrl ?? existing?.thumbnailUrl,
                    songCount: item.songCount != 0 ? item.songCount : (existing?.songCount ?? 0),
                    duration: item.duration != 0 ? item.duration : (existing?.duration ?? 0),
                    bookmarkedAt: existing?.bookmarkedAt ?? Date(),
                    isUploaded: existing?.isUploaded ?? false
                )
                try entity.save(db)
            }
            if !remoteIds.isEmpty {
                let placeholders = DatabaseService.placeholders(count: remoteIds.count)
                try db.execute(
                    sql: "UPDATE album SET bookmarked_at = NULL WHERE bookmarked_at IS NOT NULL AND id NOT IN (\(placeholders))",
                    arguments: StatementArguments(Array(remoteIds))
                )
            }
        }
        return remoteIds
    }

    func applyPodcastSync(items: [ParsedPodcast]) async throws -> Set<String> {
        let remoteIds = Set(items.map(\.browseId))
        try await db.write { db in
            for item in items {
                let existing = try PodcastEntity.fetchOne(db, key: item.browseId)
                let entity = PodcastEntity(
                    id: item.browseId,
                    name: item.name,
                    thumbnailUrl: item.thumbnailUrl ?? existing?.thumbnailUrl,
                    subscribedAt: existing?.subscribedAt ?? Date()
                )
                try entity.save(db)
            }
            if !remoteIds.isEmpty {
                let placeholders = DatabaseService.placeholders(count: remoteIds.count)
                try db.execute(
                    sql: "UPDATE podcast SET subscribed_at = NULL WHERE subscribed_at IS NOT NULL AND id NOT IN (\(placeholders))",
                    arguments: StatementArguments(Array(remoteIds))
                )
            }
        }
        return remoteIds
    }
}

// MARK: - Liked songs

extension TropLibraryStore {
    func likedPlaylistSongIdsOrdered(playlistId: String) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT song_id FROM playlist_song_map WHERE playlist_id = ? ORDER BY position",
                arguments: [playlistId]
            )
        }
    }

    func mirrorLikedSongs(orderedIds: [String], baseDate: Date) async throws {
        guard !orderedIds.isEmpty else { return }
        try await db.write { db in
            for (index, songId) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE song SET liked = 1, modify_date = ?, create_date = ? WHERE id = ?",
                    arguments: [baseDate, baseDate.addingTimeInterval(TimeInterval(-index)), songId]
                )
            }
        }
    }

    func unmarkStaleLikedSongs(excluding ids: Set<String>, graceCutoff: Date) async throws {
        try await db.write { db in
            var sql = "SELECT id FROM song WHERE liked = 1"
            if !ids.isEmpty {
                sql += " AND id NOT IN (\(DatabaseService.placeholders(count: ids.count)))"
            }
            sql += " AND modify_date < ?"
            let staleIds = try String.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(Array(ids) + [graceCutoff])
            )
            for chunk in DatabaseService.chunked(staleIds) {
                try db.execute(
                    sql: "UPDATE song SET liked = 0 WHERE id IN (\(DatabaseService.placeholders(count: chunk.count)))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    func deletePlaylistRows(playlistId: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM playlist_song_map WHERE playlist_id = ?", arguments: [playlistId])
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [playlistId])
        }
    }
}

// MARK: - Playlists

extension TropLibraryStore {
    func fetchPlaylist(id: String) async throws -> SyncPlaylist? {
        try await db.fetchOne(PlaylistEntity.self, key: id)?.toSync()
    }

    func savePlaylist(_ playlist: SyncPlaylist) async throws {
        try await db.save(PlaylistEntity(sync: playlist))
    }

    @discardableResult
    func insertOrReplacePlaylist(_ playlist: SyncPlaylist) async throws -> SyncPlaylist {
        let stored = try await db.insertOrReplace(PlaylistEntity(sync: playlist))
        return stored.toSync()
    }

    func deletePlaylist(id: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id])
        }
    }

    func deleteMapsForPlaylist(playlistId: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM playlist_song_map WHERE playlist_id = ?", arguments: [playlistId])
        }
    }

    func insertMapIgnoringConflicts(_ entry: SyncPlaylistEntry) async throws {
        _ = try await db.insert(entry.toMap(), onConflict: .ignore)
    }

    func fetchMapEntry(playlistId: String, songId: String) async throws -> SyncPlaylistEntry? {
        let maps = try await db.fetchAll(
            PlaylistSongMap.self,
            sql: "SELECT * FROM playlist_song_map WHERE playlist_id = ? AND song_id = ? LIMIT 1",
            arguments: [playlistId, songId]
        )
        return maps.first?.toSync()
    }

    func deleteMapEntry(playlistId: String, songId: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM playlist_song_map WHERE playlist_id = ? AND song_id = ?", arguments: [playlistId, songId])
        }
    }
}

// MARK: - Songs

extension TropLibraryStore {
    func fetchSong(id: String) async throws -> SyncSong? {
        try await db.fetchOne(SongEntity.self, key: id)?.toSync()
    }

    func saveSong(_ song: SyncSong) async throws {
        try await db.save(SongEntity(sync: song))
    }

    func insertSongIgnoringConflicts(_ song: SyncSong) async throws {
        _ = try await db.insert(SongEntity(sync: song), onConflict: .ignore)
    }

    func fetchOrphanSongIds() async throws -> [String] {
        try await db.orphanSongIds()
    }
}

// MARK: - Artists / albums / podcasts

extension TropLibraryStore {
    func fetchArtist(id: String) async throws -> SyncArtist? {
        try await db.fetchOne(ArtistEntity.self, key: id)?.toSync()
    }

    func saveArtist(_ artist: SyncArtist) async throws {
        try await db.save(ArtistEntity(sync: artist))
    }

    func fetchAlbum(id: String) async throws -> SyncAlbum? {
        try await db.fetchOne(AlbumEntity.self, key: id)?.toSync()
    }

    func saveAlbum(_ album: SyncAlbum) async throws {
        try await db.save(AlbumEntity(sync: album))
    }

    func fetchPodcast(id: String) async throws -> SyncPodcast? {
        try await db.fetchOne(PodcastEntity.self, key: id)?.toSync()
    }

    func savePodcast(_ podcast: SyncPodcast) async throws {
        try await db.save(PodcastEntity(sync: podcast))
    }
}

// MARK: - Entity mapping

extension SongEntity {
    init(sync: SyncSong) {
        self.init(
            id: sync.id,
            title: sync.title,
            artistName: sync.artistName,
            albumName: sync.albumName,
            duration: sync.duration,
            thumbnailUrl: sync.thumbnailUrl,
            liked: sync.liked,
            totalPlayTime: sync.totalPlayTime,
            inLibrary: sync.inLibrary,
            libraryAddToken: sync.libraryAddToken,
            libraryRemoveToken: sync.libraryRemoveToken,
            isEpisode: sync.isEpisode,
            isUploaded: sync.isUploaded,
            isVideo: sync.isVideo,
            createDate: sync.createDate,
            modifyDate: sync.modifyDate
        )
    }

    func toSync() -> SyncSong {
        SyncSong(
            id: id,
            title: title,
            artistName: artistName,
            albumName: albumName,
            duration: duration,
            thumbnailUrl: thumbnailUrl,
            liked: liked,
            totalPlayTime: totalPlayTime,
            inLibrary: inLibrary,
            libraryAddToken: libraryAddToken,
            libraryRemoveToken: libraryRemoveToken,
            isEpisode: isEpisode,
            isUploaded: isUploaded,
            isVideo: isVideo,
            createDate: createDate,
            modifyDate: modifyDate
        )
    }
}

extension ArtistEntity {
    init(sync: SyncArtist) {
        self.init(
            id: sync.id,
            name: sync.name,
            thumbnailUrl: sync.thumbnailUrl,
            bookmarkedAt: sync.bookmarkedAt,
            isPodcastChannel: sync.isPodcastChannel,
            channelId: sync.channelId
        )
    }

    func toSync() -> SyncArtist {
        SyncArtist(
            id: id,
            name: name,
            thumbnailUrl: thumbnailUrl,
            bookmarkedAt: bookmarkedAt,
            isPodcastChannel: isPodcastChannel,
            channelId: channelId
        )
    }
}

extension AlbumEntity {
    init(sync: SyncAlbum) {
        self.init(
            id: sync.id,
            title: sync.title,
            playlistId: sync.playlistId,
            thumbnailUrl: sync.thumbnailUrl,
            songCount: sync.songCount,
            duration: sync.duration,
            bookmarkedAt: sync.bookmarkedAt,
            isUploaded: sync.isUploaded
        )
    }

    func toSync() -> SyncAlbum {
        SyncAlbum(
            id: id,
            title: title,
            playlistId: playlistId,
            thumbnailUrl: thumbnailUrl,
            songCount: songCount,
            duration: duration,
            bookmarkedAt: bookmarkedAt,
            isUploaded: isUploaded
        )
    }
}

extension PlaylistEntity {
    init(sync: SyncPlaylist) {
        self.init(
            id: sync.id,
            browseId: sync.browseId,
            name: sync.name,
            thumbnailUrl: sync.thumbnailUrl,
            isEditable: sync.isEditable,
            bookmarkedAt: sync.bookmarkedAt,
            remoteSongCount: sync.remoteSongCount,
            isAutoSync: sync.isAutoSync
        )
    }

    func toSync() -> SyncPlaylist {
        SyncPlaylist(
            id: id,
            browseId: browseId,
            name: name,
            thumbnailUrl: thumbnailUrl,
            isEditable: isEditable,
            bookmarkedAt: bookmarkedAt,
            remoteSongCount: remoteSongCount,
            isAutoSync: isAutoSync
        )
    }
}

extension PodcastEntity {
    init(sync: SyncPodcast) {
        self.init(
            id: sync.id,
            name: sync.name,
            thumbnailUrl: sync.thumbnailUrl,
            subscribedAt: sync.subscribedAt
        )
    }

    func toSync() -> SyncPodcast {
        SyncPodcast(
            id: id,
            name: name,
            thumbnailUrl: thumbnailUrl,
            subscribedAt: subscribedAt
        )
    }
}

extension SyncPlaylistEntry {
    func toMap() -> PlaylistSongMap {
        PlaylistSongMap(id: nil, playlistId: playlistId, songId: songId, position: position, setVideoId: setVideoId)
    }
}

extension PlaylistSongMap {
    func toSync() -> SyncPlaylistEntry {
        SyncPlaylistEntry(playlistId: playlistId, songId: songId, position: position, setVideoId: setVideoId)
    }
}
