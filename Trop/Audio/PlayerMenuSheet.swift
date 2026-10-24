//
//  PlayerMenuSheet.swift
//  Trop
//
//  Created by 686udjie on 21/08/2026.
//

import SwiftUI
import Foundation

/// library/download/details rows.
struct PlayerMenuSheet: View {
    let song: SongItem
    /// Collapses the Big Player so the pushed page is visible underneath.
    var onCollapseRequest: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings

    enum Destination: Hashable {
        case equalizer
        case details
        case similar
    }

    // Loaded state
    @State private var pin = PinState()
    @State private var showPlaylistPicker = false
    @State private var showArtistPicker = false
    @State private var showRadioOptions = false
    @State private var isResolvingArtist = false
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        SheetChrome {
            Group {
                eqVolumeCard
                actionGrid
                MenuCard {
                    viewArtistRow
                    if let albumId = song.firstAlbumBrowseId {
                        Divider()
                        MenuRow(icon: "record.circle", title: "View Album", subtitle: song.album) {
                            navigate(.album(browseId: albumId))
                        }
                    }
                    Divider()
                    pinRow
                    Divider()
                    downloadRow
                }
                MenuCard {
                    NavigationLink(value: Destination.details) {
                        MenuRowLabel(icon: "info.circle", title: "Details", subtitle: "Metadata & stream information")
                    }
                    .buttonStyle(.plain)
                    Divider()
                    NavigationLink(value: Destination.similar) {
                        MenuRowLabel(
                            icon: "dot.radiowaves.left.and.right",
                            title: "Similar to this song",
                            subtitle: String(format: NSLocalizedString("More like “%@”", comment: "Similar songs subtitle"), song.title)
                        )
                    }
                    .buttonStyle(.plain)
                    Divider()
                    MenuRow(
                        icon: "slider.horizontal.3",
                        title: "Customize Radio",
                        subtitle: "Style, size & explicit filter"
                    ) { showRadioOptions = true }
                }
            }
            .navigationDestination(for: Destination.self) { dest in
                switch dest {
                case .equalizer:
                    EqualizerView()
                case .details:
                    SongDetailsView(song: song)
                case .similar:
                    SimilarSongsView(
                        song: song,
                        onNavigate: { navigate($0) },
                        onPlaySong: { similar, songs in
                            dismiss()
                            PlaybackQueue.play(similar, in: songs, log: Log.search, context: "SimilarTo tap")
                            AppRouter.shared.expandPlayer()
                        }
                    )
                }
            }
        }
        .confirmationDialog("View Artist", isPresented: $showArtistPicker, titleVisibility: .visible) {
            ForEach(song.artists.filter { !$0.name.isEmpty }, id: \.self) { artist in
                Button(artist.name) {
                    openArtist(artist)
                }
            }
        }
        .sheet(isPresented: $showPlaylistPicker) {
            AddSongToPlaylistSheet(song: song)
        }
        .sheet(isPresented: $showRadioOptions) {
            RadioOptionsSheet(song: song)
        }
        .task { await pin.load(videoId: song.videoId) }
    }

    // MARK: - EQ + App Volume

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    private var eqVolumeCard: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Destination.equalizer) {
                Label("EQ", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(settings.accentColor.opacity(0.15)))
                    .foregroundStyle(settings.accentColor)
            }

            Image(systemName: volumeIconName)
                .font(.callout)
                .foregroundStyle(settings.accentColor)
                .frame(width: 24)

            VolumeSlider(
                value: Binding(
                    get: { settings.playerVolume },
                    set: { newValue in
                        settings.playerVolume = newValue.clamped01
                        PlayerController.shared.applyPlayerVolume()
                    }
                ),
                accentColor: settings.accentColor
            )
            .accessibilityLabel("App volume")
        }
        .padding(16)
        .background(cardBackground)
    }

    private var volumeIconName: String {
        switch settings.playerVolume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    // MARK: - Quick Actions

    private var actionGrid: some View {
        HStack(spacing: 0) {
            actionButton(icon: "dot.radiowaves.left.and.right", label: "Start Radio") {
                startRadio()
            }
            separator
            actionButton(icon: "music.note.list", label: "Playlist") {
                showPlaylistPicker = true
            }
            separator
            actionButton(icon: "link", label: "Copy Link") {
                UIPasteboard.general.string = song.webUrl
                dismiss()
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var separator: some View {
        Color(.separator)
            .frame(width: 0.5, height: 28)
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(settings.accentColor)
                Text(LocalizedStringKey(label))
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Download Row

    private var downloadRow: some View {
        let state = downloadManager.state(for: song.videoId)
        return Group {
            switch state {
            case .completed:
                MenuRow(icon: "checkmark.circle.fill", title: "Remove Download", destructive: true) {
                    Task { await downloadManager.delete(videoId: song.videoId) }
                }
            case .downloading:
                MenuRow(icon: "arrow.down.circle", title: "Downloading…") {}
                    .disabled(true)
            case .notStarted, .failed:
                MenuRow(icon: "arrow.down.circle", title: "Download") {
                    Task { await downloadManager.download(song: song) }
                }
            }
        }
    }

    // MARK: - Library Rows

    private var viewArtistRow: some View {
        Button {
            handleViewArtist()
        } label: {
            HStack(spacing: 14) {
                if isResolvingArtist {
                    ProgressView()
                        .frame(width: 26)
                } else {
                    Image(systemName: "music.mic")
                        .font(.system(size: 18))
                        .foregroundStyle(settings.accentColor)
                        .frame(width: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("View Artist")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(song.artistNamesDisplay)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(song.artists.isEmpty || isResolvingArtist)
    }

    private var pinRow: some View {
        MenuRow(
            icon: pin.isPinned ? "pin.fill" : "pin",
            title: pin.isPinned ? "Unpin from Quick Picks" : "Pin to Quick Picks"
        ) {
            Task { await pin.toggle(song: song) }
        }
    }

    // MARK: - State

    private func startRadio() {
        PlaybackQueue.startRadio(for: song)
        dismiss()
    }

    private func navigate(_ route: DetailRoute) {
        dismiss()
        onCollapseRequest?()
        // Appends directly to the selected tab's NavigationPath — plain state
        // mutation, so it lands even while the player is tearing down.
        AppRouter.shared.open(route)
    }

    private func handleViewArtist() {
        guard !isResolvingArtist else { return }
        let namedArtists = song.artists.filter { !$0.name.isEmpty }
        if namedArtists.count > 1 {
            showArtistPicker = true
            return
        }
        guard let artist = namedArtists.first else { return }
        openArtist(artist)
    }

    private func openArtist(_ artist: YTArtist) {
        if let id = artist.id {
            navigate(.artist(browseId: id))
            return
        }
        resolveArtistByName(artist.name)
    }

    private func resolveArtistByName(_ name: String) {
        guard !name.isEmpty else { return }
        isResolvingArtist = true
        Task {
            defer { isResolvingArtist = false }
            var browseId: String?
            do {
                let json = try await SearchService.shared.search(query: name)
                browseId = SearchParser.parseSearchResults(from: json)
                    .flatMap(\.items)
                    .compactMap { item -> String? in
                        if case .artist(let artist) = item { return artist.browseId }
                        return nil
                    }
                    .first
            } catch {
                browseId = nil
            }
            if let browseId {
                navigate(.artist(browseId: browseId))
            }
        }
    }
}

// MARK: - Add to Playlist Picker

/// Lets the user pick which playlist to add `song` to, or create a new one.
struct AddSongToPlaylistSheet: View {
    let song: SongItem
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [PlaylistEntity] = []
    @State private var isLoading = true
    @State private var addedTo: Set<String> = []
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistTitle = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "music.note.list",
                        description: Text("Create one below to start collecting songs.")
                    )
                } else {
                    List(playlists, id: \.id) { playlist in
                        Button {
                            addTo(playlist)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .foregroundStyle(.primary)
                                    if let count = playlist.remoteSongCount {
                                        Text("\(count) songs")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if addedTo.contains(playlist.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newPlaylistTitle = ""
                        showNewPlaylistAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New playlist")
                }
            }
            .textPrompt(
                "New Playlist",
                isPresented: $showNewPlaylistAlert,
                placeholder: "Playlist name",
                text: $newPlaylistTitle,
                okTitle: "Create",
                message: Text("Adds “\(song.title)” once created.")
            ) {
                Task { await createAndAdd() }
            }
            .task { await loadPlaylists() }
        }
        .appSheetChrome()
    }

    private func loadPlaylists() async {
        playlists = (try? await DatabaseService.shared.fetchPlaylists(limit: 100)) ?? []
        isLoading = false
    }

    private func addTo(_ playlist: PlaylistEntity) {
        guard !addedTo.contains(playlist.id) else { return }
        Task {
            do {
                try await SyncBridge.mutations.addToPlaylist(playlistId: playlist.id, songId: song.videoId)
                addedTo.insert(playlist.id)
            } catch {
                addedTo.remove(playlist.id)
            }
        }
    }

    private func createAndAdd() async {
        let title = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let playlistId = try await SyncBridge.mutations.createPlaylist(title: title)
            try await SyncBridge.mutations.addToPlaylist(playlistId: playlistId, songId: song.videoId)
            await loadPlaylists()
            addedTo.insert(playlistId)
        } catch {
            // Leave the sheet open so the user can retry.
        }
    }
}

// MARK: - Details (Nerdy Metadata)

struct SongDetailsView: View {
    let song: SongItem

    @State private var stream: PlaybackResult?
    @State private var formatEntity: FormatEntity?
    @State private var viewCountText: String?
    @State private var resolvedDuration: Int = 0

    private var effectiveDuration: Int {
        song.duration > 0 ? song.duration : resolvedDuration
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                trackSection
                streamSection
                statsSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMetadata() }
    }

    // MARK: Sections

    private var trackSection: some View {
        section("Track") {
            row("Title", song.title)
            row("Artists", song.artistNamesDisplay)
            if let album = song.album {
                row("Album", album)
            }
            row("Duration", effectiveDuration.formattedDuration)
            row("Video ID", song.videoId, monospaced: true)
        }
    }

    @ViewBuilder
    private var streamSection: some View {
        section("Stream") {
            if let s = stream {
                row("Client", s.clientName)
                row("ITAG", "\(s.itag)", monospaced: true)
                row("Bitrate", "\(s.bitrate / 1000) kbps")
                row("Audio quality", s.audioQuality.replacingOccurrences(of: "AUDIO_QUALITY_", with: ""))
                if let loudness = s.loudnessDb {
                    row("Loudness", String(format: "%.1f dB", loudness))
                }
                row("Expires in", "\(s.expiresInSeconds)s")
            } else if let f = formatEntity {
                row("Source", "Cached format")
                row("ITAG", "\(f.itag)", monospaced: true)
                row("Bitrate", "\(f.bitrate / 1000) kbps")
                if f.contentLength > 0 {
                    row("Size", ByteCountFormatter.string(fromByteCount: f.contentLength, countStyle: .file))
                }
            } else {
                row("Status", "Not resolved yet")
            }
        }
    }

    private var statsSection: some View {
        section("Stats") {
            row("Views", viewCountText ?? "Loading…")
        }
    }

    // MARK: Building Blocks

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey(title))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(LocalizedStringKey(label))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .footnote.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: Helpers

    private func loadMetadata() async {
        if song.duration <= 0 {
            if let duration = await InnerTubeClient.tropShared.resolveDuration(videoId: song.videoId) {
                resolvedDuration = duration
            }
        }
        stream = await StreamCache.shared.get(videoId: song.videoId)
        formatEntity = try? await DatabaseService.shared.fetchOne(FormatEntity.self, key: song.videoId)
        if let response: PlayerResponse = try? await InnerTubeClient.tropShared.playerResponse(videoId: song.videoId),
           let raw = response.videoDetails?.viewCount,
           let count = Int(raw) {
            viewCountText = count.formattedViews()
        } else {
            viewCountText = "Unavailable"
        }
    }
}

// MARK: - Volume Slider 

/// Thick capsule slider with a round thumb
private struct VolumeSlider: View {
    @Binding var value: Double
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(accentColor)
                    .frame(width: max(16, width * value))
                Circle()
                    .fill(Color.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.25), radius: 2.5, x: 0, y: 1)
                    .offset(x: min(width - 15, max(0, width * value - 7.5)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = (gesture.location.x / width).clamped01
                    }
            )
        }
        .frame(height: 28)
    }
}
