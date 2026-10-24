//
//  PersonalizationService.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import Foundation

actor PersonalizationService {
    nonisolated static let shared = PersonalizationService()
    private let db = DatabaseService.shared
    private let innerTube = InnerTubeClient.tropShared

    private var enrichmentTasks: [Task<Void, Never>] = []

    // MARK: - Phase 1: Local sections (fast, load immediately)

    func buildQuickPicks(limit: Int = 12) async -> HomeSection {
        guard let songs = try? await db.fetchLikedSongs(), !songs.isEmpty else {
            return .quickPicks(items: [])
        }
        let picked = songs.shuffled().prefix(max(limit, 1))
        let initialItems = picked.toSongItems().map(YTItem.song)
        let section = HomeSection.quickPicks(items: Array(initialItems))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.enrichLikedSongs(songs: Array(picked))
        }
        recordEnrichment(task)
        return section
    }

    func buildKeepListening() async -> HomeSection {
        var items: [YTItem] = []
        var recentSongs: [SongEntity] = []

        if let fetched = try? await db.fetchRecentSongs(days: 30, limit: 6) {
            recentSongs = fetched
            for song in fetched where items.count < 8 {
                items.append(.song(SongItem(entity: song)))
            }
        }

        if let albums = try? await db.fetchAlbums(limit: 4) {
            for album in albums where items.count < 12 {
                items.append(.album(AlbumItem(entity: album)))
            }
        }

        if let artists = try? await db.fetchArtists(limit: 4) {
            for artist in artists where items.count < 16 {
                items.append(.artist(ArtistItem(entity: artist)))
            }
        }

        let section = HomeSection.keepListening(items: items)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.enrichLikedSongs(songs: recentSongs)
        }
        recordEnrichment(task)
        return section
    }

    private func enrichLikedSongs(songs: [SongEntity]) async {
        for entity in songs where entity.title.isEmpty {
            guard let metadata = try? await fetchSongMetadata(videoId: entity.id),
                  !metadata.title.isEmpty else { continue }
            let enriched = SongEntity(sync: SyncSong.merging(entity.toSync(), with: metadata))
            try? await db.save(enriched)
        }
    }

    func buildForgottenFavorites() async -> HomeSection {
        guard let songs = try? await db.fetchForgottenFavorites(days: 60, limit: 10), !songs.isEmpty else {
            return .forgottenFavorites(items: [])
        }
        let initialItems = songs.toSongItems().map(YTItem.song)
        let section = HomeSection.forgottenFavorites(items: initialItems)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.enrichForgottenFavorites()
        }
        recordEnrichment(task)
        return section
    }

    private func enrichForgottenFavorites() async {
        guard let songs = try? await db.fetchForgottenFavorites(days: 60, limit: 10) else { return }
        let toEnrich = songs.filter { $0.title.isEmpty }.prefix(3)
        guard !toEnrich.isEmpty else { return }
        var didEnrich = false
        for entity in toEnrich {
            guard let metadata = try? await fetchSongMetadata(videoId: entity.id),
                  !metadata.title.isEmpty else { continue }
            let enriched = SongEntity(sync: SyncSong.merging(entity.toSync(), with: metadata))
            try? await db.save(enriched)
            didEnrich = true
        }
        if didEnrich {
            await MainActor.run {
                NotificationCenter.default.post(name: .personalizationDataUpdated, object: nil)
            }
        }
    }

    // MARK: - Phase 2: API-based sections (load in background)

    func buildAccountPlaylists() async -> HomeSection {
        guard await isLoggedIn() else { return .accountPlaylists(items: []) }
        do {
            let json = try await innerTube.browse(browseId: "FEmusic_liked_playlists")
            let playlists = LibraryBrowseParser.parsePlaylists(from: json)
            let items = playlists.map {
                YTItem.playlist(PlaylistItem(
                    id: $0.browseId, title: $0.title,
                    author: nil, thumbnailUrl: $0.thumbnailUrl,
                    songCount: $0.songCount
                ))
            }
            return .accountPlaylists(items: items)
        } catch {
            return .accountPlaylists(items: [])
        }
    }

    func buildDailyDiscover() async -> HomeSection {
        guard await isLoggedIn() else { return .dailyDiscover(items: []) }
        guard let likedSongs = try? await db.fetchLikedSongs(), !likedSongs.isEmpty else {
            return .dailyDiscover(items: [])
        }

        let seeds = likedSongs.shuffled().prefix(3)
        var seenIds = Set<String>()
        var discovered: [YTItem] = []

        for song in seeds {
            guard discovered.count < 10 else { break }
            guard let radio = try? await fetchRadio(videoId: song.id),
                  !radio.songs.isEmpty else { continue }
            let related = radio.songs.map { YTItem.song($0) }
            for item in related {
                if let videoId = item.videoId, !seenIds.contains(videoId) {
                    seenIds.insert(videoId)
                    discovered.append(item)
                }
                if discovered.count >= 10 { break }
            }
        }

        return .dailyDiscover(items: discovered)
    }

    func buildSimilarRecommendations() async -> [HomeSection] {
        guard await isLoggedIn() else { return [] }
        guard let topArtists = try? await db.fetchArtists(limit: 3), !topArtists.isEmpty else {
            return []
        }

        var sections: [HomeSection] = []
        for artist in topArtists.prefix(3) {
            guard sections.count < 3 else { break }
            guard let related = try? await innerTube.browse(browseId: artist.id),
                  let items = parseRelatedItems(from: related), !items.isEmpty else { continue }
            let title = String(
                format: NSLocalizedString("Similar to %@", comment: "Similar artist section title"),
                artist.name
            )
            sections.append(.similarRecommendation(items: items, title: title))
        }
        return sections
    }

    func buildFromTheCommunity() async -> HomeSection {
        guard await isLoggedIn() else { return .fromTheCommunity(items: []) }
        guard let topArtists = try? await db.fetchArtists(limit: 3), !topArtists.isEmpty else {
            return .fromTheCommunity(items: [])
        }

        var seenIds = Set<String>()
        var communityPlaylists: [YTItem] = []

        for artist in topArtists {
            guard communityPlaylists.count < 5 else { break }
            guard let json = try? await innerTube.browse(browseId: artist.id) else { continue }
            let playlists = LibraryBrowseParser.extractCommunityPlaylists(from: json)
            for playlist in playlists {
                let pid = LibraryBrowseParser.normalizePlaylistId(playlist.browseId)
                guard !seenIds.contains(pid) else { continue }
                seenIds.insert(pid)
                communityPlaylists.append(.playlist(PlaylistItem(
                    id: pid, title: playlist.title,
                    author: nil, thumbnailUrl: playlist.thumbnailUrl,
                    songCount: playlist.songCount
                )))
                if communityPlaylists.count >= 5 { break }
            }
        }

        return .fromTheCommunity(items: communityPlaylists)
    }

    // MARK: - Helpers

    /// Tracks a background enrichment task so `drainEnrichments()` can
    /// wait for it to complete.
    private func recordEnrichment(_ task: Task<Void, Never>) {
        enrichmentTasks.append(task)
        Task { [weak self] in
            await task.value
            await self?.removeEnrichment(task)
        }
    }

    private func removeEnrichment(_ task: Task<Void, Never>) {
        enrichmentTasks.removeAll { $0 == task }
    }

    /// Awaits all in-flight background enrichment tasks. Use this before
    /// re-reading derived state so the next query sees freshly-saved data.
    func drainEnrichments() async {
        let tasks = enrichmentTasks
        for task in tasks { await task.value }
    }

    private func fetchSongMetadata(videoId: String) async throws -> SongMetadata? {
        let json: [String: Any]
        do {
            json = try await innerTube.player(videoId: videoId)
        } catch {
            return nil
        }
        guard let videoDetails = json["videoDetails"] as? [String: Any] else { return nil }
        let title = videoDetails["title"] as? String ?? ""
        let author = videoDetails["author"] as? String
        let lengthSeconds = videoDetails["lengthSeconds"] as? String
        let duration = lengthSeconds.flatMap { Int($0) } ?? 0
        var thumbnailUrl: String?
        if let thumbs = videoDetails["thumbnail"] as? [String: Any],
           let list = thumbs["thumbnails"] as? [[String: Any]] {
            thumbnailUrl = list.last?["url"] as? String
        }
        guard !title.isEmpty else { return nil }
        return SongMetadata(title: title, artistName: author, thumbnailUrl: thumbnailUrl, duration: duration, albumName: nil)
    }

    private func isLoggedIn() async -> Bool {
        let store = CookieStore()
        return await store.isLoggedIn()
    }

    func fetchRadio(videoId: String) async throws -> (songs: [SongItem], currentIndex: Int) {
        try await fetchRadio(videoId: videoId, options: .default)
    }

    func fetchRadio(videoId: String, options: RadioOptions) async throws -> (songs: [SongItem], currentIndex: Int) {
        let playlistId = "RDAMVM\(videoId)"
        let json = try await innerTube.next(videoId: videoId, playlistId: playlistId)
        let panel = try extractPlaylistPanel(from: json)
        var songs: [(SongItem, Bool)] = []
        for entry in panel.contents {
            guard songs.count < 50 else { break }
            if let renderer = entry["playlistPanelVideoRenderer"] as? [String: Any],
               let song = parsePlaylistPanelVideoRenderer(renderer) {
                songs.append((song, renderer["selected"] as? Bool ?? false))
            }
        }
        guard !songs.isEmpty else { throw NSError(domain: "fetchRadio", code: 1, userInfo: [:]) }
        let currentIndex = songs.firstIndex(where: { $0.1 }) ?? 0
        var resultSongs = songs.map(\.0)
        if let automixItems = await tryResolveAutomix(from: panel) {
            let deduped = automixItems.filter { a in !resultSongs.contains(where: { $0.videoId == a.videoId }) }
            resultSongs += deduped
        }
        switch options.style {
        case .similar:
            break
        case .variety:
            if resultSongs.count > 2 {
                let head = Array(resultSongs.prefix(2))
                let tail = Array(resultSongs.dropFirst(2)).shuffled()
                resultSongs = head + tail
            }
        case .deepCuts:
            if resultSongs.count > 5 {
                resultSongs = Array(resultSongs.dropFirst(3))
            }
        }
        if !options.allowExplicit {
            resultSongs = resultSongs.filter { !$0.isExplicit }
        }
        resultSongs = Array(resultSongs.prefix(max(1, options.limit)))
        guard !resultSongs.isEmpty else { throw NSError(domain: "fetchRadio", code: 1, userInfo: [:]) }
        let clampedIndex = min(currentIndex, resultSongs.count - 1)
        return (resultSongs, clampedIndex)
    }

    private struct PlaylistPanel { let contents: [[String: Any]] }

    private func extractPlaylistPanel(from json: [String: Any]) throws -> PlaylistPanel {
        guard let contents = json["contents"] as? [String: Any],
              let singleColumn = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbed = singleColumn["tabbedRenderer"] as? [String: Any],
              let watchNext = tabbed["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNext["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let content = tabRenderer["content"] as? [String: Any],
              let queueRenderer = content["musicQueueRenderer"] as? [String: Any],
              let queueContent = queueRenderer["content"] as? [String: Any],
              let playlistPanel = queueContent["playlistPanelRenderer"] as? [String: Any],
              let panelContents = playlistPanel["contents"] as? [[String: Any]] else {
            throw NSError(domain: "fetchRadio", code: 2, userInfo: [:])
        }
        return PlaylistPanel(contents: panelContents)
    }

    private func tryResolveAutomix(from panel: PlaylistPanel) async -> [SongItem]? {
        guard let lastEntry = panel.contents.last,
              let automix = lastEntry["automixPreviewVideoRenderer"] as? [String: Any],
              let content = automix["content"] as? [String: Any],
              let autoRenderer = content["automixPlaylistVideoRenderer"] as? [String: Any],
              let navEndpoint = autoRenderer["navigationEndpoint"] as? [String: Any],
              let watchPlaylist = navEndpoint["watchPlaylistEndpoint"] as? [String: Any],
              let playlistId = watchPlaylist["playlistId"] as? String else { return nil }
        let autoVideoId = watchPlaylist["videoId"] as? String
        guard let autoJson = try? await innerTube.next(videoId: autoVideoId, playlistId: playlistId),
              let autoPanel = try? extractPlaylistPanel(from: autoJson) else { return nil }
        var songs: [SongItem] = []
        for entry in autoPanel.contents {
            guard songs.count < 50 else { break }
            if let renderer = entry["playlistPanelVideoRenderer"] as? [String: Any],
               let song = parsePlaylistPanelVideoRenderer(renderer) { songs.append(song) }
        }
        return songs.isEmpty ? nil : songs
    }

    private func parsePlaylistPanelVideoRenderer(_ renderer: [String: Any]) -> SongItem? {
        guard let vid = renderer["videoId"] as? String else { return nil }
        let title = InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? "Unknown"
        let bylineRuns = InnerTubeJSON.rawRuns(renderer["longBylineText"] as? [String: Any] ?? renderer["shortBylineText"] as? [String: Any])
        let artists = parseArtists(from: bylineRuns)
        let thumbnail = InnerTubeJSON.nestedThumbnailURL(renderer)
        let duration = DurationFormat.parseRendererDuration(renderer)
        return SongItem(
            videoId: vid, title: title, artists: artists, duration: duration,
            thumbnailUrl: thumbnail, isExplicit: false, musicVideoType: VideoAvailability.rowMusicVideoType(renderer)
        )
    }

    private func parseArtists(from bylineRuns: [[String: Any]]) -> [YTArtist] {
        ArtistCredits.parse(runs: bylineRuns).map { YTArtist(name: $0.name, id: $0.browseId) }
    }

    private func parseRelatedItems(from json: [String: Any]) -> [YTItem]? {
        guard let sections = BrowseLens.browseSections(json) else { return nil }

        var items: [YTItem] = []
        for section in sections {
            guard let shelf = section["musicShelfRenderer"] as? [String: Any],
                  let contents = shelf["contents"] as? [[String: Any]] else { continue }
            for entry in contents {
                if items.count >= 10 { break }
                if let renderer = entry["musicResponsiveListItemRenderer"] as? [String: Any] {
                    if let song = SongItem.from(renderer) {
                        items.append(.song(song))
                    }
                }
            }
        }
        return items.isEmpty ? nil : items
    }
}
