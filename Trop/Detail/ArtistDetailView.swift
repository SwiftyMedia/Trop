//
//  ArtistDetailView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import Nuke
import SwiftUI

// MARK: - View Model

@MainActor
@Observable
final class ArtistDetailViewModel {
    let browseId: String
    var artist: ArtistDetailInfo?
    var isLoading = true
    var error: Error?

    private let innerTube = InnerTubeClient.tropShared

    init(browseId: String) {
        self.browseId = browseId
    }

    /// Fetches artist browse page from InnerTube and parses the response.
    func load() async {
        isLoading = true
        error = nil

        do {
            let json = try await innerTube.browse(browseId: browseId)
            let parsed = Self.parseArtistDetail(from: json, browseId: browseId)
            Self.preloadHeroArtwork(for: parsed.thumbnailUrl)
            artist = parsed
            isLoading = false
        } catch {
            self.error = error
            isLoading = false
        }
    }
}

// MARK: - Parser

extension ArtistDetailViewModel {
    /// Parses InnerTube browse JSON into an ArtistDetailInfo.
    /// Handles both musicImmersiveHeaderRenderer and musicResponsiveHeaderRenderer for the header,
    /// then extracts top songs from musicShelfRenderer and albums, singles, videos,
    /// playlists and related artists from musicCarouselShelfRenderer shelves.
    static func parseArtistDetail(from json: [String: Any], browseId: String) -> ArtistDetailInfo {
        var name = "Unknown Artist"
        var thumbnailUrl: String?
        var subscriberCountText: String?
        var descriptionText: String?
        var isSubscribed = false
        var songs: [SongItem] = []
        var buckets = ArtistCarouselBuckets()

        // --- Header ---
        // Artist pages can use either an immersive header (large background image)
        // or a responsive header (smaller, more compact).
        if let header = json["header"] as? [String: Any] {
            if let immersive = header["musicImmersiveHeaderRenderer"] as? [String: Any] {
                name = InnerTubeJSON.runsText(immersive["title"] as? [String: Any]) ?? "Unknown Artist"
                thumbnailUrl = InnerTubeJSON.musicThumbnailURL(immersive)
                let subscription = extractSubscriptionDetails(from: immersive)
                isSubscribed = subscription.isSubscribed ?? false
                subscriberCountText = subscription.subscriberCountText
            } else if let responsive = header["musicResponsiveHeaderRenderer"] as? [String: Any] {
                name = InnerTubeJSON.runsText(responsive["title"] as? [String: Any]) ?? "Unknown Artist"
                thumbnailUrl = InnerTubeJSON.musicThumbnailURL(responsive)
                let subscription = extractSubscriptionDetails(from: responsive)
                isSubscribed = subscription.isSubscribed ?? false
                subscriberCountText = subscription.subscriberCountText
            }
        }

        if name == "Unknown Artist" || thumbnailUrl == nil,
           let microformat = json["microformat"] as? [String: Any],
           let mfRenderer = microformat["microformatDataRenderer"] as? [String: Any] {
            if name == "Unknown Artist", let mfTitle = mfRenderer["title"] as? String {
                name = mfTitle
            }
            if thumbnailUrl == nil, let thumb = mfRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumb["thumbnails"] as? [[String: Any]],
               let last = thumbnails.last,
               let url = last["url"] as? String {
                thumbnailUrl = url
            }
            if descriptionText == nil, let desc = mfRenderer["description"] as? String {
                descriptionText = desc
            }
        }

        // --- Sections ---
        if let sections = BrowseLens.browseSections(json) {

            for sectionDict in sections {
                // musicShelfRenderer typically contains a list of songs
                if let shelf = sectionDict["musicShelfRenderer"] as? [String: Any],
                   let items = shelf["contents"] as? [[String: Any]] {
                    for itemDict in items {
                        if let renderer = itemDict["musicResponsiveListItemRenderer"] as? [String: Any],
                           let song = SongItem.from(renderer) {
                            songs.append(song)
                        }
                    }
                }

                // musicCarouselShelfRenderer holds albums, singles, videos,
                // playlists and related artists — classified per shelf below.
                if let carousel = sectionDict["musicCarouselShelfRenderer"] as? [String: Any],
                   let items = carousel["contents"] as? [[String: Any]] {
                    let shelfTitle = extractCarouselTitle(carousel)
                    for itemDict in items {
                        guard let twoRow = itemDict["musicTwoRowItemRenderer"] as? [String: Any] else { continue }
                        classifyCarouselItem(twoRow, shelfTitle: shelfTitle, buckets: &buckets)
                    }
                }
            }
        }

        return ArtistDetailInfo(
            name: name,
            thumbnailUrl: thumbnailUrl,
            subscriberCountText: subscriberCountText,
            descriptionText: descriptionText,
            isSubscribed: isSubscribed,
            browseId: browseId,
            songs: songs,
            albums: buckets.albums,
            singles: buckets.singles,
            videos: buckets.videos,
            playlists: buckets.playlists,
            relatedArtists: buckets.relatedArtists
        )
    }

    /// Buckets for one artist page's carousel shelves.
    private struct ArtistCarouselBuckets {
        var albums: [AlbumItem] = []
        var singles: [AlbumItem] = []
        var videos: [SongItem] = []
        var playlists: [PlaylistItem] = []
        var relatedArtists: [ArtistItem] = []
    }

    /// Routes one carousel tile into albums, singles, videos, playlists or
    /// related artists based on its page type (and shelf/subtitle hints for
    /// singles & EPs, which share the album page type).
    private static func classifyCarouselItem(
        _ twoRow: [String: Any],
        shelfTitle: String,
        buckets: inout ArtistCarouselBuckets
    ) {
        let pageType = HomePageParser.extractPageType(twoRow)
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            guard let albumItem = AlbumItem.from(twoRow) else { return }
            if isSingleOrEP(shelfTitle: shelfTitle, renderer: twoRow) {
                buckets.singles.append(albumItem)
            } else {
                buckets.albums.append(albumItem)
            }
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            if let artistItem = ArtistItem.from(twoRow) {
                buckets.relatedArtists.append(artistItem)
            }
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            if let playlistItem = PlaylistItem.from(twoRow) {
                buckets.playlists.append(playlistItem)
            }
        default:
            // Music videos expose a watch endpoint instead of a browse page.
            if pageType == "MUSIC_PAGE_TYPE_VIDEO" || HomePageParser.hasWatchEndpoint(twoRow),
               let video = SongItem.from(twoRow) {
                buckets.videos.append(video)
            }
        }
    }

    /// Singles & EPs share the album page type, so the shelf title
    /// ("Singles & EPs") or subtitle ("Single • 2024") decides.
    private static let singleOrEPWords: Set<String> = ["single", "singles", "ep", "eps"]

    private static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
    }

    private static func isSingleOrEP(shelfTitle: String, renderer: [String: Any]) -> Bool {
        if words(in: shelfTitle).contains(where: singleOrEPWords.contains) {
            return true
        }
        let subtitleWords = InnerTubeJSON.runsTexts(renderer["subtitle"] as? [String: Any])
            .flatMap { words(in: $0) }
        return subtitleWords.contains(where: singleOrEPWords.contains)
    }

    /// Warms Nuke's cache before the artist screen appears, avoiding a second
    /// visible loading state for the immersive header artwork.
    private static func preloadHeroArtwork(for thumbnailUrl: String?) {
        guard let artworkURL = ArtworkURLs.sized(thumbnailUrl, width: 1200, height: 1200),
              let url = URL(string: artworkURL) else {
            return
        }

        ArtworkLoader.warm(url)
    }

    /// YouTube Music subscription payloads vary: the subscribed state is in `subscriptionButton`, 
    /// the count in `subscriptionButton2`, and older responses include a notification toggle.
    private static func extractSubscriptionDetails(
        from header: [String: Any]
    ) -> (isSubscribed: Bool?, subscriberCountText: String?) {
        var isSubscribed: Bool?
        var subscriberCountText: String?

        let buttons = ["subscriptionButton2", "subscriptionButton"]
            .compactMap { header[$0] as? [String: Any] }

        for button in buttons {
            if let subscribe = button["subscribeButtonRenderer"] as? [String: Any] {
                if isSubscribed == nil {
                    isSubscribed = subscribe["subscribed"] as? Bool
                }

                if subscriberCountText == nil {
                    for key in ["subscriberCountWithSubscribeText", "longSubscriberCountText", "shortSubscriberCountText"] {
                        if let count = InnerTubeJSON.runsText(subscribe[key] as? [String: Any]), !count.isEmpty {
                            subscriberCountText = count
                            break
                        }
                    }
                }
            }

            if let toggle = button["subscriptionNotificationToggleButtonRenderer"] as? [String: Any] {
                if isSubscribed == nil {
                    isSubscribed = toggle["subscribed"] as? Bool
                }
                if subscriberCountText == nil,
                   let count = InnerTubeJSON.runsText(toggle["subscribedText"] as? [String: Any]),
                   !count.isEmpty {
                    subscriberCountText = count
                }
            }
        }

        return (isSubscribed, subscriberCountText)
    }

    /// Extracts the title from a musicCarouselShelfBasicHeaderRenderer.
    private static func extractCarouselTitle(_ carousel: [String: Any]) -> String {
        guard let header = carousel["header"] as? [String: Any],
              let basicHeader = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
              let title = InnerTubeJSON.runsText(basicHeader["title"] as? [String: Any]) else {
            return "Unknown"
        }
        return title
    }
}

// MARK: - View

struct ArtistDetailView: View {
    let browseId: String
    @State private var viewModel: ArtistDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var scrollOffset: CGFloat = 0
    @State private var linkCopied = false
    @State private var linkResetTask: Task<Void, Never>?

    private static let barFadeStart: CGFloat = 80
    private static let barFadeDistance: CGFloat = 120

    private var barProgress: CGFloat {
        min(max((scrollOffset - Self.barFadeStart) / Self.barFadeDistance, 0), 1)
    }

    init(browseId: String) {
        self.browseId = browseId
        _viewModel = State(initialValue: ArtistDetailViewModel(browseId: browseId))
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                DetailStateContainer(
                    isLoading: viewModel.isLoading,
                    error: viewModel.error,
                    data: viewModel.artist,
                    noun: "artist",
                    emptyIcon: "music.mic"
                ) { artist in
                    artistContent(for: artist)
                }
            }
            .scrollDisabled(viewModel.isLoading || viewModel.error != nil || viewModel.artist == nil)
            .miniPlayerTracksScroll()
            .onScrollGeometryChange(
                for: CGFloat.self,
                of: { $0.contentOffset.y },
                action: { _, newOffset in
                    scrollOffset = newOffset
                }
            )
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                guard viewModel.isLoading else { return }
                await viewModel.load()
            }

            customTopBar
        }
        .onDisappear { linkResetTask?.cancel() }
    }

    private var customTopBar: some View {
        HStack(spacing: 8) {
            topBarBackButton

            if let artist = viewModel.artist {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(barProgress)
            }

            Spacer(minLength: 0)

            topBarCopyLinkButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color(.systemBackground)
                .opacity(barProgress)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(barProgress)
        }
    }

    private var topBarBackButton: some View {
        topBarCircleButton(
            systemName: "chevron.left",
            accessibilityLabel: "Back",
            action: { dismiss() }
        )
    }

    private var topBarCopyLinkButton: some View {
        topBarCircleButton(
            systemName: linkCopied ? "checkmark" : "link",
            fadedColor: linkCopied ? Color.accentColor : .primary,
            accessibilityLabel: linkCopied ? "Artist link copied" : "Copy artist link",
            action: { copyArtistLink() }
        )
        .disabled(viewModel.artist == nil)
    }

    /// Round top-bar button matching the back chevron: white with shadow over
    /// the banner artwork, crossfading to `fadedColor` as the bar fills in.
    private func topBarCircleButton(
        systemName: String,
        fadedColor: Color = .primary,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action, label: {
            ZStack {
                Image(systemName: systemName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .opacity(1 - barProgress)
                Image(systemName: systemName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(fadedColor)
                    .opacity(barProgress)
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func copyArtistLink() {
        guard let artist = viewModel.artist,
              let url = URL(string: "https://music.youtube.com/channel/\(artist.browseId)") else { return }
        UIPasteboard.general.string = url.absoluteString
        linkCopied = true
        linkResetTask?.cancel()
        linkResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            linkCopied = false
        }
    }

    @ViewBuilder
    private func artistContent(for artist: ArtistDetailInfo) -> some View {
        LazyVStack(spacing: 0) {
            header(for: artist)

            if !artist.songs.isEmpty {
                songsSection(songs: artist.songs)
            }

            if !artist.albums.isEmpty {
                albumsSection(albums: artist.albums)
            }

            if !artist.singles.isEmpty {
                singlesSection(singles: artist.singles)
            }

            if !artist.videos.isEmpty {
                videosSection(videos: artist.videos)
            }

            if !artist.playlists.isEmpty {
                playlistsSection(playlists: artist.playlists)
            }

            if !artist.relatedArtists.isEmpty {
                relatedArtistsSection(artists: artist.relatedArtists)
            }

            if let description = artist.descriptionText, !description.isEmpty {
                aboutSection(description: description)
            }

            if artist.songs.isEmpty && artist.albums.isEmpty && artist.singles.isEmpty
                && artist.videos.isEmpty && artist.playlists.isEmpty && artist.relatedArtists.isEmpty {
                VStack(spacing: 8) {
                    Spacer().frame(height: 40)
                    Text("No content found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func header(for artist: ArtistDetailInfo) -> some View {
        if horizontalSizeClass == .regular {
            GeometryReader { proxy in
                headerBanner(
                    for: artist,
                    size: CGSize(width: proxy.size.width, height: Self.iPadBannerHeight)
                )
            }
            .frame(height: Self.iPadBannerHeight)
            .accessibilityElement(children: .contain)
        } else {
            // iPhone: full-width square banner.
            GeometryReader { proxy in
                headerBanner(for: artist, size: proxy.size)
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .contain)
        }
    }

    private static let iPadBannerHeight: CGFloat = 400

    private func headerBanner(for artist: ArtistDetailInfo, size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(.systemGray5)

            AsyncImageView(
                url: ArtworkURLs.sized(artist.thumbnailUrl, width: 1200, height: 1200),
                contentMode: .fill
            )
            .frame(width: size.width, height: size.height)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                Text(artist.name)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

                HStack(spacing: 12) {
                    Button(action: { toggleSubscribe(artist) }, label: {
                        Text(artist.isSubscribed ? "Subscribed" : "Subscribe")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(artist.isSubscribed ? Color.white : Color.black)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(
                                Capsule()
                                    .fill(artist.isSubscribed ? Color.clear : Color.white)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(.white, lineWidth: artist.isSubscribed ? 1.5 : 0)
                            )
                    })
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    if let subText = artist.subscriberCountText, !subText.isEmpty {
                        Text(subscriberLabel(for: subText))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                    }

                    Button(action: { shufflePlay(artist) }, label: {
                        Image(systemName: "shuffle")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.accentColor))
                    })
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shuffle artist")
                }
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 32 : 20)
            .padding(.bottom, 24)
        }
    }

    private func subscriberLabel(for count: String) -> String {
        if count.localizedCaseInsensitiveContains("subscriber") {
            return count
        }
        return String(format: NSLocalizedString("%@ subscribers", comment: "Artist subscribers count"), count)
    }

    @ViewBuilder
    private func aboutSection(description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey("About"))
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 16)

            Text(description)
                .font(.body)
                .foregroundColor(.primary)
                .lineLimit(5)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func songsSection(songs: [SongItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey("Songs"))
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 16)
                .padding(.top, 20)

            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                                Button(action: { playSong(song) }, label: {
                    HStack(spacing: 12) {
                        AsyncImageView(url: song.thumbnailUrl)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Text(song.artists.map(\.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(song.duration.formattedDuration)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                })
                .buttonStyle(.plain)

                if index < songs.count - 1 {
                    Divider()
                        .padding(.leading, 72)
                }
            }
        }
    }

    @ViewBuilder
    private func albumsSection(albums: [AlbumItem]) -> some View {
        carouselSection(title: "Albums") {
            ForEach(albums.indices, id: \.self) { i in
                let album = albums[i]
                NavigationLink(value: DetailRoute.album(browseId: album.browseId)) {
                    MediaGridCell(
                        thumbnailUrl: album.thumbnailUrl,
                        title: album.title,
                        subtitle: album.artists.map(\.name).joined(separator: ", "),
                        size: 156
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func singlesSection(singles: [AlbumItem]) -> some View {
        carouselSection(title: "Singles & EPs") {
            ForEach(singles.indices, id: \.self) { i in
                let single = singles[i]
                NavigationLink(value: DetailRoute.album(browseId: single.browseId)) {
                    MediaGridCell(
                        thumbnailUrl: single.thumbnailUrl,
                        title: single.title,
                        subtitle: single.artists.map(\.name).joined(separator: ", "),
                        size: 156
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func videosSection(videos: [SongItem]) -> some View {
        carouselSection(title: "Videos") {
            ForEach(videos.indices, id: \.self) { i in
                let video = videos[i]
                Button(action: { playVideo(video) }, label: {
                    VStack(alignment: .leading, spacing: 6) {
                        AsyncImageView(url: video.thumbnailUrl)
                            .frame(width: 200, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(video.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .frame(width: 200, alignment: .leading)
                        if !video.duration.formattedDuration.isEmpty {
                            Text(video.duration.formattedDuration)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                })
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func playlistsSection(playlists: [PlaylistItem]) -> some View {
        carouselSection(title: "Playlists") {
            ForEach(playlists.indices, id: \.self) { i in
                let playlist = playlists[i]
                NavigationLink(value: DetailRoute.playlist(playlistId: playlist.id)) {
                    MediaGridCell(
                        thumbnailUrl: playlist.thumbnailUrl,
                        title: playlist.title,
                        subtitle: playlistSubtitle(playlist.author),
                        size: 156
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func relatedArtistsSection(artists: [ArtistItem]) -> some View {
        carouselSection(title: "Fans Also Like", spacing: 16) {
            ForEach(artists.indices, id: \.self) { i in
                let related = artists[i]
                NavigationLink(value: DetailRoute.artist(browseId: related.browseId)) {
                    VStack(spacing: 8) {
                        AsyncImageView(url: related.thumbnailUrl)
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                        Text(related.name)
                            .lineLimit(1)
                            .font(.callout)
                    }
                    .frame(width: 120)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Shared shell for the artist page's horizontal carousels.
    @ViewBuilder
    private func carouselSection<Content: View>(
        title: String,
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    content()
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func shufflePlay(_ artist: ArtistDetailInfo) {
        PlaybackQueue.playShuffled(artist.songs, log: Log.artistDetail, context: "Shuffle playback")
    }

    private func playSong(_ song: SongItem) {
        guard let artist = viewModel.artist else { return }
        PlaybackQueue.play(song, in: artist.songs, log: Log.artistDetail, context: "Playback")
    }

    private func playVideo(_ video: SongItem) {
        guard let artist = viewModel.artist else { return }
        PlaybackQueue.play(video, in: artist.videos, log: Log.artistDetail, context: "Video playback")
    }

    /// The tile subtitle's first run is the generic "Playlist" type label —
    /// redundant under the Playlists header, so only show a real author.
    private func playlistSubtitle(_ author: String?) -> String? {
        guard let author, !author.isEmpty,
              author.localizedCaseInsensitiveCompare("playlist") != .orderedSame else { return nil }
        return author
    }

    private func toggleSubscribe(_ artist: ArtistDetailInfo) {
        loggedTask(Log.artistDetail, "Subscribe failed") {
            let channelId = artist.browseId
            let entity = ArtistEntity(
                id: artist.browseId,
                name: artist.name,
                thumbnailUrl: artist.thumbnailUrl,
                bookmarkedAt: artist.isSubscribed ? nil : Date(),
                isPodcastChannel: false,
                channelId: channelId
            )
            try await DatabaseService.shared.insertOrReplace(entity)

            if artist.isSubscribed {
                try await SyncBridge.mutations.unsubscribeArtist(channelId: channelId, artistId: artist.browseId)
            } else {
                try await SyncBridge.mutations.subscribeArtist(channelId: channelId, artistId: artist.browseId)
            }

            await MainActor.run {
                if let current = viewModel.artist {
                    viewModel.artist = ArtistDetailInfo(
                        name: current.name,
                        thumbnailUrl: current.thumbnailUrl,
                        subscriberCountText: current.subscriberCountText,
                        descriptionText: current.descriptionText,
                        isSubscribed: !current.isSubscribed,
                        browseId: current.browseId,
                        songs: current.songs,
                        albums: current.albums,
                        singles: current.singles,
                        videos: current.videos,
                        playlists: current.playlists,
                        relatedArtists: current.relatedArtists
                    )
                }
            }
        }
    }
}
