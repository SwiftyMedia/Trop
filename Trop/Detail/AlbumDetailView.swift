//
//  AlbumDetailView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import SwiftUI

// MARK: - View Model

@MainActor
@Observable
final class AlbumDetailViewModel {
    let browseId: String
    var album: AlbumDetailInfo?
    var isLoading = true
    var error: Error?
    var isSaved = false

    private let innerTube = InnerTubeClient.tropShared

    init(browseId: String) {
        self.browseId = browseId
    }

    /// Fetches album browse page from InnerTube and parses the response.
    func load() async {
        Log.albumDetailViewModel.debug("Loading album browseId=\(browseId)")
        isLoading = true
        error = nil

        do {
            let json = try await innerTube.browse(browseId: browseId)
            Log.albumDetailViewModel.debug("Got browse response, parsing...")
            let parsed = Self.parseAlbumDetail(from: json, browseId: browseId)
            album = parsed
            Log.albumDetailViewModel.debug("Parsed album: \(parsed.title), \(parsed.songs.count) songs")
            isLoading = false
            await refreshSavedState()
        } catch {
            Log.albumDetailViewModel.error("Failed: \(error)")
            self.error = error
            isLoading = false
        }
    }

    func refreshSavedState() async {
        let entity = try? await DatabaseService.shared.fetchOne(AlbumEntity.self, key: browseId)
        isSaved = entity?.bookmarkedAt != nil
    }

    func toggleSave() async {
        guard let album else { return }
        let currentlySaved = isSaved
        isSaved = !currentlySaved
        do {
            if currentlySaved {
                try await SyncBridge.mutations.unsaveAlbum(browseId: browseId)
            } else {
                try await SyncBridge.mutations.saveAlbum(
                    browseId: browseId,
                    title: album.title,
                    thumbnailUrl: album.thumbnailUrl,
                    playlistId: album.playlistId,
                    songCount: album.songCount,
                    duration: album.duration
                )
            }
        } catch {
            Log.albumDetailViewModel.error("Toggle save failed: \(error)")
        }
        await refreshSavedState()
    }
}

// MARK: - Parser

extension AlbumDetailViewModel {
    // swiftlint:disable cyclomatic_complexity
    /// Parses InnerTube browse JSON into an AlbumDetailInfo.
    /// Extracts header metadata (title, artists, year, song count, duration, thumbnail)
    /// from musicDetailHeaderRenderer and songs from musicPlaylistShelfRenderer.
    /// Branch count is inherent to tolerant InnerTube JSON parsing.
    static func parseAlbumDetail(from json: [String: Any], browseId: String) -> AlbumDetailInfo {
        var title = "Unknown Album"
        var artists: [YTArtist] = []
        var year: Int?
        var songCount = 0
        var duration = 0
        var thumbnailUrl: String?
        var playlistId: String?
        var songs: [SongItem] = []

        // Resolve first tab section (exists in both layouts)
        let firstTabSection: [String: Any]? = BrowseLens.firstSectionItem(json)

        // --- Header: musicResponsiveHeaderRenderer (modern two-column albums) ---
        if let responsiveHeader = firstTabSection?["musicResponsiveHeaderRenderer"] as? [String: Any] {
            title = InnerTubeJSON.runsText(responsiveHeader["title"] as? [String: Any]) ?? title

            // Artists from straplineTextOne
            if let strapline = responsiveHeader["straplineTextOne"] as? [String: Any],
               let runs = strapline["runs"] as? [[String: Any]] {
                artists = ArtistCredits.parse(runs: runs).map { YTArtist(name: $0.name, id: $0.browseId) }
            }
            // Artist fallback from subtitle runs
            if artists.isEmpty,
               let subtitle = responsiveHeader["subtitle"] as? [String: Any],
               let runs = subtitle["runs"] as? [[String: Any]] {
                artists = ArtistCredits.parse(runs: runs).map { YTArtist(name: $0.name, id: $0.browseId) }
            }

            // Year / songCount / duration from secondSubtitle
            if let secondSubtitle = responsiveHeader["secondSubtitle"] as? [String: Any],
               let runs = secondSubtitle["runs"] as? [[String: Any]] {
                for run in runs {
                    guard let text = run["text"] as? String else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if let yearVal = Int(trimmed), trimmed.count == 4, yearVal > 1900, yearVal < 2100 {
                        year = yearVal
                    } else if trimmed.contains("song") || trimmed.contains("Song") ||
                              trimmed.contains("track") || trimmed.contains("Track") {
                        let nums = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
                        if let count = nums.first { songCount = count }
                    } else if trimmed.contains(":") {
                        duration = DurationFormat.parseClock(trimmed) ?? 0
                    }
                }
            }

            thumbnailUrl = InnerTubeJSON.musicThumbnailURL(responsiveHeader)
        }

        // --- Header fallback: musicDetailHeaderRenderer (legacy / single-column) ---
        if title == "Unknown Album" {
            let legacyHeader: [String: Any]? =
                (json["header"] as? [String: Any])?["musicDetailHeaderRenderer"] as? [String: Any]

            if let detailHeader = legacyHeader {
                title = InnerTubeJSON.runsText(detailHeader["title"] as? [String: Any]) ?? title

                if let subtitle = detailHeader["subtitle"] as? [String: Any],
                   let runs = subtitle["runs"] as? [[String: Any]] {
                    artists += ArtistCredits.parse(runs: runs).map { YTArtist(name: $0.name, id: $0.browseId) }
                }

                if let secondSubtitle = detailHeader["secondSubtitle"] as? [String: Any],
                   let runs = secondSubtitle["runs"] as? [[String: Any]] {
                    for run in runs {
                        guard let text = run["text"] as? String else { continue }
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        if let yearVal = Int(trimmed), trimmed.count == 4, yearVal > 1900, yearVal < 2100 {
                            year = yearVal
                        } else if trimmed.contains("song") || trimmed.contains("Song") ||
                                  trimmed.contains("track") || trimmed.contains("Track") {
                            let nums = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
                            if let count = nums.first { songCount = count }
                        } else if trimmed.contains(":") {
                            duration = DurationFormat.parseClock(trimmed) ?? 0
                        }
                    }
                }

                if thumbnailUrl == nil { thumbnailUrl = InnerTubeJSON.musicThumbnailURL(detailHeader) }

                // Extract playlistId from menu items (needed for playback queue)
                if let menu = detailHeader["menu"] as? [String: Any],
                   let menuRenderer = menu["menuRenderer"] as? [String: Any],
                   let items = menuRenderer["items"] as? [[String: Any]] {
                    for item in items {
                        if let menuNav = item["menuNavigationItemRenderer"] as? [String: Any],
                           let nav = menuNav["navigationEndpoint"] as? [String: Any],
                           let watch = nav["watchEndpoint"] as? [String: Any],
                           let pid = watch["playlistId"] as? String {
                            playlistId = pid
                        }
                    }
                }
            }
        }

        // Fallback: extract playlistId from microformat URL query parameter
        // URL format: https://music.youtube.com/playlist?list=OLAK5uy_...
        if playlistId == nil,
           let microformat = json["microformat"] as? [String: Any],
           let mfRenderer = microformat["microformatDataRenderer"] as? [String: Any],
           let urlCanonical = mfRenderer["urlCanonical"] as? String,
           let components = URLComponents(string: urlCanonical) {
            if let listParam = components.queryItems?.first(where: { $0.name == "list" })?.value {
                playlistId = listParam
            }
        }

        // --- Songs ---
        // Album track rows carry no per-row thumbnail; fall back to the album art (same as Metrolist).
        func parseSongsFromShelf(_ shelfDict: [String: Any], fallbackThumbnail: String?) -> [SongItem] {
            var result: [SongItem] = []
            let items: [[String: Any]]? =
                (shelfDict["musicPlaylistShelfRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]
                ?? (shelfDict["musicShelfRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]
            for itemDict in items ?? [] {
                if let renderer = itemDict["musicResponsiveListItemRenderer"] as? [String: Any],
                   var song = SongItem.from(renderer) {
                    if song.thumbnailUrl == nil { song.thumbnailUrl = fallbackThumbnail }
                    result.append(song)
                }
            }
            return result
        }

        if let twoCol = (json["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any] {
            // Songs are in secondaryContents for two-column albums
            if let secondary = twoCol["secondaryContents"] as? [String: Any],
               let sectionList = secondary["sectionListRenderer"] as? [String: Any],
               let secondarySections = sectionList["contents"] as? [[String: Any]] {
                for section in secondarySections {
                    songs += parseSongsFromShelf(section, fallbackThumbnail: thumbnailUrl)
                }
            }
            // Fallback: songs might still be in first tab section (e.g. musicShelfRenderer)
            if songs.isEmpty, let firstSection = firstTabSection {
                songs += parseSongsFromShelf(firstSection, fallbackThumbnail: thumbnailUrl)
            }
        } else if let sections = BrowseLens.browseSections(json) {
            for section in sections {
                songs += parseSongsFromShelf(section, fallbackThumbnail: thumbnailUrl)
            }
        }

        // Set songCount from actual count if header value wasn't parsed
        if songCount == 0 { songCount = songs.count }

        return AlbumDetailInfo(
            title: title,
            artists: artists,
            year: year,
            songCount: songCount,
            duration: duration,
            thumbnailUrl: thumbnailUrl,
            playlistId: playlistId,
            browseId: browseId,
            songs: songs
        )
    }
    // swiftlint:enable cyclomatic_complexity
}

// MARK: - View

struct AlbumDetailView: View {
    let browseId: String
    @State private var viewModel: AlbumDetailViewModel
    @State private var pendingRoute: DetailRoute?
    @State private var showMoreSheet = false

    @Environment(\.dismiss) private var dismiss

    init(browseId: String) {
        self.browseId = browseId
        _viewModel = State(initialValue: AlbumDetailViewModel(browseId: browseId))
    }

    var body: some View {
        ScrollView {
            DetailStateContainer(
                isLoading: viewModel.isLoading,
                error: viewModel.error,
                data: viewModel.album,
                noun: "album",
                emptyIcon: "music.note"
            ) { album in
                albumContent(for: album)
            }
        }
        .scrollDisabled(viewModel.isLoading || viewModel.error != nil || viewModel.album == nil)
        .miniPlayerTracksScroll()
        .navigationTitle(viewModel.album?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel.isLoading else { return }
            await viewModel.load()
        }
        .detailRouteSheet(item: $pendingRoute)
    }

    @ViewBuilder
    private func albumContent(for album: AlbumDetailInfo) -> some View {
        LazyVStack(spacing: 0) {
            header(for: album)
                .padding(.bottom, 8)

            if album.songs.isEmpty {
                VStack(spacing: 8) {
                    Spacer().frame(height: 40)
                    Text("No songs found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                songList(for: album)
            }
        }
    }

    @ViewBuilder
    private func header(for album: AlbumDetailInfo) -> some View {
        VStack(spacing: 12) {
            // Album artwork
            HeroArtworkView(url: album.thumbnailUrl)

            // Album title
            Text(album.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Clickable artist names
            if !album.artists.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(album.artists.enumerated()), id: \.offset) { i, artist in
                        if i > 0 {
                            Text(", ")
                                .foregroundColor(.secondary)
                        }
                        if let artistId = artist.id {
                            NavigationLink(value: DetailRoute.artist(browseId: artistId)) {
                                Text(artist.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(artist.name)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Metadata: year • song count • duration
            let metaParts = metaStrings(for: album)
            if !metaParts.isEmpty {
                Text(metaParts.joined(separator: " • "))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            // Action buttons: shuffle, play, more (matches playlist header)
            PlaybackControlsView(
                showsMore: true,
                onPlay: { playAll(album) },
                onShuffle: { shufflePlay(album) },
                onMore: { showMoreSheet = true }
            )
        }
        .padding(.vertical, 16)
        .sheet(isPresented: $showMoreSheet) {
            if let album = viewModel.album {
                AlbumMoreSheet(
                    album: album,
                    isSaved: viewModel.isSaved,
                    onToggleSave: { Task { await viewModel.toggleSave() } }
                )
            }
        }
    }

    @ViewBuilder
    private func songList(for album: AlbumDetailInfo) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(album.songs.enumerated()), id: \.offset) { index, song in
                SongRowView(
                    song: song,
                    onTap: { playSong(song, in: album) },
                    onNavigate: { pendingRoute = $0 }
                )

                if index < album.songs.count - 1 {
                    Divider()
                        .padding(.leading, 68)
                }
            }
        }
    }

    // MARK: - Actions

    private func playAll(_ album: AlbumDetailInfo) {
        PlaybackQueue.play(album.songs, log: Log.albumDetail, context: "Playing from album \(album.title)")
    }

    private func shufflePlay(_ album: AlbumDetailInfo) {
        PlaybackQueue.playShuffled(album.songs, log: Log.albumDetail, context: "Shuffle playing from album \(album.title)")
    }

    private func playSong(_ song: SongItem, in album: AlbumDetailInfo) {
        PlaybackQueue.play(song, in: album.songs, log: Log.albumDetail, context: "Playing \(song.title)")
    }

    // MARK: - Helpers

    /// Builds metadata strings like "2024 • 12 songs • 45:30"
    private func metaStrings(for album: AlbumDetailInfo) -> [String] {
        var parts: [String] = []
        if let year = album.year { parts.append("\(year)") }
        if album.songCount > 0 { parts.append("\(album.songCount) song\(album.songCount != 1 ? "s" : "")") }
        if album.duration > 0 { parts.append(album.duration.formattedDuration) }
        return parts
    }
}

// MARK: - Album More Sheet

/// Overflow menu matching PlaylistMoreSheet, with Save to Library as the
/// first row (mirrors album.bookmarked_at).
struct AlbumMoreSheet: View {
    let album: AlbumDetailInfo
    let isSaved: Bool
    var onToggleSave: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome {
            MenuCard {
                MenuRow(
                    icon: isSaved ? "bookmark.fill" : "bookmark",
                    title: isSaved ? "Saved" : "Save to Library",
                    subtitle: isSaved ? "Remove from your library" : "Add to your library"
                ) {
                    onToggleSave?()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "list.bullet",
                    title: "Add to Queue",
                    subtitle: "Add to the end of the queue"
                ) {
                    addToQueue()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "square.and.arrow.down",
                    title: "Download",
                    subtitle: "Download all songs for offline playback"
                ) {
                    downloadAll()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "square.and.arrow.up",
                    title: "Share",
                    subtitle: "Share this album with others"
                ) {
                    share()
                    dismiss()
                }
            }
        }
    }

    private func addToQueue() {
        let np = NowPlaying.shared
        np.queueSongs.append(contentsOf: album.songs)
        np.persistQueueState()
    }

    private func downloadAll() {
        for song in album.songs {
            Task { await DownloadManager.shared.download(song: song) }
        }
    }

    private func share() {
        guard let url = URL(string: "https://music.youtube.com/browse/\(album.browseId)") else { return }
        presentShareSheet(items: [url])
        dismiss()
    }
}
