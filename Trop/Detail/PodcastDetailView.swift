//
//  PodcastDetailView.swift
//  Trop
//
//  Created by 686udjie on 06/07/2026.
//

import SwiftUI

// MARK: - View Model

@MainActor
@Observable
final class PodcastDetailViewModel {
    let browseId: String
    var podcast: PodcastDetailInfo?
    var isLoading = true
    var error: Error?
    var isSubscribed = false

    private let innerTube = InnerTubeClient.tropShared

    init(browseId: String) {
        self.browseId = browseId
    }

    func load() async {
        isLoading = true
        error = nil

        do {
            let json = try await innerTube.browse(browseId: browseId)
            let parsed = Self.parsePodcastDetail(from: json, browseId: browseId)
            Log.podcastDetail.debug("title=\(parsed.title) author=\(parsed.author ?? "nil") episodes=\(parsed.episodes.count)")
            podcast = parsed
            isLoading = false
            await refreshSubscribedState()
            // Seed from the remote subscribed state when nothing is stored locally yet.
            if parsed.isSubscribed {
                let local: PodcastEntity? = try? await DatabaseService.shared.fetchOne(PodcastEntity.self, key: browseId)
                if local?.subscribedAt == nil {
                    isSubscribed = true
                }
            }

            let fresh = await EpisodePlaybackStore.shared.syncKnownEpisodes(
                parsed.episodes, podcastId: browseId, podcastName: parsed.title
            )
            if SettingsStore.shared.autoDownloadNewEpisodes, !fresh.isEmpty {
                for episode in fresh.prefix(10) {
                    await DownloadManager.shared.download(song: episode.toSongItem())
                }
            }
        } catch {
            self.error = error
            isLoading = false
        }
    }

    func refreshSubscribedState() async {
        let entity = try? await DatabaseService.shared.fetchOne(PodcastEntity.self, key: browseId)
        isSubscribed = entity?.subscribedAt != nil
    }

    func toggleSubscribe() async {
        guard let podcast else { return }
        let currentlySubscribed = isSubscribed
        isSubscribed = !currentlySubscribed
        do {
            if currentlySubscribed {
                try await SyncBridge.mutations.unsubscribePodcast(browseId: browseId)
            } else {
                try await SyncBridge.mutations.subscribePodcast(
                    browseId: browseId,
                    name: podcast.title,
                    thumbnailUrl: podcast.thumbnailUrl
                )
            }
        } catch {
            Log.podcastDetail.error("Toggle subscribe failed: \(error)")
        }
        await refreshSubscribedState()
    }
}

// MARK: - Parser

/// Header fields extracted from the podcast browse response.
private struct ParsedPodcastHeader {
    var title = "Unknown Podcast"
    var author: String?
    var descriptionText: String?
    var thumbnailUrl: String?
    var isSubscribed = false
}

/// Subtitle metadata for one episode row.
private struct ParsedEpisodeMeta {
    var publishDate: String?
    var viewsText: String?
    var duration = 0
}

extension PodcastDetailViewModel {
    static func parsePodcastDetail(from json: [String: Any], browseId: String) -> PodcastDetailInfo {
        let header = parsePodcastHeader(from: json)
        var episodes = collectPodcastEpisodes(from: json)

        // Episodes carry no artist runs; stamp the show name so queue rows,
        // the mini player and menus show it (matching the big player author).
        if !episodes.isEmpty {
            let showName = header.author ?? header.title
            episodes = episodes.map { episode in
                var stamped = episode
                if stamped.artists.isEmpty {
                    stamped.artists = [YTArtist(name: showName)]
                }
                return stamped
            }
        }

        return PodcastDetailInfo(
            title: header.title,
            author: header.author,
            descriptionText: header.descriptionText,
            thumbnailUrl: header.thumbnailUrl,
            browseId: browseId,
            isSubscribed: header.isSubscribed,
            episodes: episodes
        )
    }
}

// MARK: - Podcast header parsing

extension PodcastDetailViewModel {
    /// Reads title/author/description/artwork/subscribed state from the
    /// immersive header, responsive header and microformat fallbacks.
    private static func parsePodcastHeader(from json: [String: Any]) -> ParsedPodcastHeader {
        var header = ParsedPodcastHeader()

        let firstTabSection = BrowseLens.firstSectionItem(json)
            .flatMap { $0["itemSectionRenderer"] as? [String: Any] }
            .flatMap { ($0["contents"] as? [[String: Any]])?.first }
            ?? BrowseLens.firstSectionItem(json)

        // Podcast show pages render an immersive header at the top level
        // (title, show description, artwork) — this is where the full
        // show blurb lives.
        if let topHeader = json["header"] as? [String: Any],
           let immersive = topHeader["musicImmersiveHeaderRenderer"] as? [String: Any] {
            applyImmersiveHeader(immersive, to: &header)
        }

        let renderer: [String: Any]? =
            firstTabSection?["musicResponsiveHeaderRenderer"] as? [String: Any]
            ?? (json["header"] as? [String: Any]).flatMap {
                $0["musicDetailHeaderRenderer"] as? [String: Any]
                ?? $0["musicResponsiveHeaderRenderer"] as? [String: Any]
            }
        if let renderer {
            applyResponsiveHeader(renderer, to: &header)
        }

        // Last resort: microformat description (always present on browse pages).
        if header.descriptionText == nil || header.descriptionText?.isEmpty == true {
            let microformat = (json["microformat"] as? [String: Any])?["microformatDataRenderer"] as? [String: Any]
            header.descriptionText = microformat?["description"] as? String
        }
        return header
    }

    private static func applyImmersiveHeader(_ immersive: [String: Any], to header: inout ParsedPodcastHeader) {
        header.title = InnerTubeJSON.runsText(immersive["title"] as? [String: Any]) ?? header.title
        if header.thumbnailUrl == nil {
            header.thumbnailUrl = InnerTubeJSON.musicThumbnailURL(immersive)
        }
        if let descDict = immersive["description"] as? [String: Any] {
            let shelf = descDict["musicDescriptionShelfRenderer"] as? [String: Any]
            if let desc = ((shelf?["description"] as? [String: Any]).flatMap({ InnerTubeJSON.runsText($0) })
                ?? InnerTubeJSON.runsText(descDict)), !desc.isEmpty {
                header.descriptionText = desc
            }
        }
        if header.author == nil {
            header.author = InnerTubeJSON.runsTexts(immersive["subtitle"] as? [String: Any]).first
                ?? InnerTubeJSON.runsTexts(immersive["straplineTextOne"] as? [String: Any]).first
        }
    }

    private static func applyResponsiveHeader(_ renderer: [String: Any], to header: inout ParsedPodcastHeader) {
        header.title = InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? header.title
        header.thumbnailUrl = header.thumbnailUrl ?? InnerTubeJSON.musicThumbnailURL(renderer)

        // The show blurb is usually nested one level deeper:
        // description.musicDescriptionShelfRenderer.description.runs.
        // Never clobber the immersive-header description already found.
        if header.descriptionText == nil {
            let shelf = (renderer["description"] as? [String: Any])?["musicDescriptionShelfRenderer"] as? [String: Any]
            header.descriptionText = (shelf?["description"] as? [String: Any])
                .flatMap { InnerTubeJSON.runsText($0) }
                ?? (renderer["description"] as? [String: Any])
                .flatMap { InnerTubeJSON.runsText($0) }
                ?? (renderer["descriptionText"] as? [String: Any])
                .flatMap { InnerTubeJSON.runsText($0) }
                ?? renderer["description"] as? String
        }

        applyHeaderButtons(renderer, to: &header)
        applyHeaderSubtitle(renderer, to: &header)
    }

    /// Subscribed state from the header action buttons, when present.
    private static func applyHeaderButtons(_ renderer: [String: Any], to header: inout ParsedPodcastHeader) {
        guard let buttons = renderer["buttons"] as? [[String: Any]] else { return }
        for button in buttons {
            if let toggle = button["toggleButtonRenderer"] as? [String: Any],
               let toggled = toggle["isToggled"] as? Bool, toggled {
                header.isSubscribed = true
            }
            if let subscribe = button["subscribeButtonRenderer"] as? [String: Any],
               let subscribed = subscribe["subscribed"] as? Bool {
                header.isSubscribed = subscribed
            }
        }
    }

    private static func applyHeaderSubtitle(_ renderer: [String: Any], to header: inout ParsedPodcastHeader) {
        if header.author == nil,
           let strapline = renderer["straplineTextOne"] as? [String: Any],
           let runs = strapline["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String {
            header.author = text
        }

        if header.author == nil || header.descriptionText == nil,
           let subtitle = renderer["subtitle"] as? [String: Any],
           let runs = subtitle["runs"] as? [[String: Any]] {
            for run in runs {
                guard let text = run["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "•" { continue }
                if header.author == nil {
                    header.author = trimmed
                } else if header.descriptionText == nil, trimmed.count > 3 {
                    // Second distinct subtitle run is often the show blurb.
                    header.descriptionText = trimmed
                }
            }
        }

        if header.descriptionText == nil,
           let secondSubtitle = renderer["secondSubtitle"] as? [String: Any],
           let text = InnerTubeJSON.runsText(secondSubtitle),
           !text.isEmpty,
           !text.localizedCaseInsensitiveContains("episode") {
            header.descriptionText = text
        }
    }
}

// MARK: - Podcast episode parsing

extension PodcastDetailViewModel {
    /// Podcast episodes use musicMultiRowListItemRenderer inside
    /// secondaryContents.sectionListRenderer.contents[].musicShelfRenderer.contents
    /// or musicPlaylistShelfRenderer.contents.
    static func collectPodcastEpisodes(from json: [String: Any]) -> [EpisodeItem] {
        var episodes: [EpisodeItem] = []

        // Primary: twoColumnBrowseResultsRenderer.secondaryContents
        if let twoCol = (json["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any],
           let secondary = twoCol["secondaryContents"] as? [String: Any],
           let sectionList = secondary["sectionListRenderer"] as? [String: Any],
           let sectionContents = sectionList["contents"] as? [[String: Any]] {
            for section in sectionContents {
                if let isr = section["itemSectionRenderer"] as? [String: Any],
                   let innerContents = isr["contents"] as? [[String: Any]] {
                    for inner in innerContents {
                        episodes += parseShelfContents(inner)
                    }
                } else {
                    episodes += parseShelfContents(section)
                }
            }
        }

        // Fallback: singleColumnBrowseResultsRenderer
        if episodes.isEmpty,
           let sections = BrowseLens.browseSections(json) {
            for section in sections {
                if let isr = section["itemSectionRenderer"] as? [String: Any],
                   let innerContents = isr["contents"] as? [[String: Any]] {
                    for inner in innerContents {
                        episodes += parseShelfContents(inner)
                    }
                } else {
                    episodes += parseShelfContents(section)
                }
            }
        }
        return episodes
    }

    private static func parseShelfContents(_ shelfDict: [String: Any]) -> [EpisodeItem] {
        if let shelf = shelfDict["musicShelfRenderer"] as? [String: Any],
           let contents = shelf["contents"] as? [[String: Any]] {
            return parseContentItems(contents)
        }
        if let shelf = shelfDict["musicPlaylistShelfRenderer"] as? [String: Any],
           let contents = shelf["contents"] as? [[String: Any]] {
            return parseContentItems(contents)
        }
        return []
    }

    private static func parseContentItems(_ contentItems: [[String: Any]]) -> [EpisodeItem] {
        var result: [EpisodeItem] = []
        for item in contentItems {
            if let multiRow = item["musicMultiRowListItemRenderer"] as? [String: Any],
               let episode = parseMultiRowEpisode(multiRow) {
                result.append(episode)
            } else if let responsive = item["musicResponsiveListItemRenderer"] as? [String: Any],
                      let episode = EpisodeItem.from(responsive) {
                result.append(episode)
            }
        }
        return result
    }

    static func parseMultiRowEpisode(_ renderer: [String: Any]) -> EpisodeItem? {
        guard let onTap = renderer["onTap"] as? [String: Any],
              let watch = onTap["watchEndpoint"] as? [String: Any],
              let videoId = watch["videoId"] as? String else { return nil }

        let title = InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? "Unknown"
        let thumbnailUrl = multiRowThumbnailUrl(renderer)
        var duration = progressRendererDuration(renderer)
        let meta = episodeSubtitleMeta(renderer, fallbackDuration: duration == 0)
        if duration == 0 { duration = meta.duration }

        // Per-episode description snippet (shown under the title like YTM).
        let episodeDescription = (renderer["description"] as? [String: Any])
            .flatMap { InnerTubeJSON.runsText($0) }
            ?? renderer["description"] as? String

        return EpisodeItem(
            videoId: videoId,
            title: title,
            artists: [],
            duration: duration,
            thumbnailUrl: thumbnailUrl,
            publishDate: meta.publishDate,
            descriptionText: episodeDescription,
            viewsText: meta.viewsText
        )
    }

    private static func multiRowThumbnailUrl(_ renderer: [String: Any]) -> String? {
        guard let thumbRenderer = renderer["thumbnail"] as? [String: Any],
              let musicThumb = thumbRenderer["musicThumbnailRenderer"] as? [String: Any],
              let thumb = musicThumb["thumbnail"] as? [String: Any],
              let thumbnails = thumb["thumbnails"] as? [[String: Any]],
              let last = thumbnails.last,
              let url = last["url"] as? String else { return nil }
        return url
    }

    /// Most reliable duration source: the playback progress renderer.
    private static func progressRendererDuration(_ renderer: [String: Any]) -> Int {
        guard let progress = renderer["playbackProgress"] as? [String: Any],
              let progressRenderer = progress["musicPlaybackProgressRenderer"] as? [String: Any],
              let durationText = InnerTubeJSON.runsText(progressRenderer["durationText"] as? [String: Any]),
              !durationText.isEmpty else { return 0 }
        return DurationFormat.parseClock(durationText)
            ?? DurationFormat.parseSpoken(durationText)
            ?? 0
    }

    /// Subtitle format: "17k views • 4 hr ago • 1 hr 23 mins".
    private static func episodeSubtitleMeta(
        _ renderer: [String: Any],
        fallbackDuration: Bool
    ) -> ParsedEpisodeMeta {
        var meta = ParsedEpisodeMeta()
        guard let subtitle = renderer["subtitle"] as? [String: Any],
              let runs = subtitle["runs"] as? [[String: Any]] else {
            return meta
        }
        let texts = runs.compactMap { $0["text"] as? String }
        let separated = texts.filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
        for text in separated {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()
            if lower.contains("ago") {
                // Relative date ("4 hr ago") — never a duration.
                if meta.publishDate == nil { meta.publishDate = trimmed }
            } else if trimmed.contains(":") {
                if fallbackDuration, meta.duration == 0 { meta.duration = DurationFormat.parseClock(trimmed) ?? 0 }
            } else if fallbackDuration, meta.duration == 0, let spoken = DurationFormat.parseSpoken(trimmed) {
                meta.duration = spoken
            } else if lower.contains("view") || lower.contains("listening") || lower.contains("download") {
                meta.viewsText = trimmed
            } else if meta.publishDate == nil {
                meta.publishDate = trimmed
            }
        }
        return meta
    }
}

// MARK: - View

struct PodcastDetailView: View {
    let browseId: String
    @State private var viewModel: PodcastDetailViewModel
    @State private var pendingRoute: DetailRoute?
    @State private var showMoreSheet = false

    @Environment(\.dismiss) private var dismiss

    init(browseId: String) {
        self.browseId = browseId
        _viewModel = State(initialValue: PodcastDetailViewModel(browseId: browseId))
    }

    var body: some View {
        ScrollView {
            DetailStateContainer(
                isLoading: viewModel.isLoading,
                error: viewModel.error,
                data: viewModel.podcast,
                noun: "podcast",
                emptyIcon: "antenna.radiowaves.left.and.right"
            ) { podcast in
                podcastContent(for: podcast)
            }
        }
        .scrollDisabled(viewModel.isLoading || viewModel.error != nil || viewModel.podcast == nil)
        .miniPlayerTracksScroll()
        .navigationTitle(viewModel.podcast?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel.isLoading else { return }
            await viewModel.load()
        }
        .sheet(isPresented: $showMoreSheet) {
            if let podcast = viewModel.podcast {
                PodcastMoreSheet(
                    podcast: podcast,
                    isSubscribed: viewModel.isSubscribed,
                    onToggleSubscribe: { Task { await viewModel.toggleSubscribe() } },
                    onPlayAll: { playAll(podcast) }
                )
            }
        }
        .detailRouteSheet(item: $pendingRoute)
    }

    @ViewBuilder
    private func podcastContent(for podcast: PodcastDetailInfo) -> some View {
        LazyVStack(spacing: 0) {
            header(for: podcast)
                .padding(.bottom, 8)

            if podcast.episodes.isEmpty {
                VStack(spacing: 8) {
                    Spacer().frame(height: 40)
                    Text("No episodes found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                episodeList(for: podcast)
            }
        }
    }

    @ViewBuilder
    private func header(for podcast: PodcastDetailInfo) -> some View {
        // YouTube Music-style podcast header: artwork on top, show details
        // stacked underneath, then a Subscribe pill + playlist-style ⋮
        // overflow button. No big play button — playback starts per-episode.
        VStack(spacing: 10) {
            HeroArtworkView(url: podcast.thumbnailUrl)

            Text(podcast.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let author = podcast.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

            if !podcast.episodes.isEmpty {
                Text("\(podcast.episodes.count) episode\(podcast.episodes.count != 1 ? "s" : "")")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            if let desc = podcast.descriptionText, !desc.isEmpty {
                ExpandableDescriptionText(text: desc, collapsedLimit: 160, alignment: .center)
                    .padding(.horizontal, 32)
                    .padding(.top, 2)
            }

            // Subscribe + overflow, matching the playlist header controls.
            HStack(spacing: 16) {
                Button(action: {
                    Task { await viewModel.toggleSubscribe() }
                }, label: {
                    Label(
                        viewModel.isSubscribed ? "Subscribed" : "Subscribe",
                        systemImage: viewModel.isSubscribed ? "bookmark.fill" : "bookmark"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.isSubscribed ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(
                        Capsule()
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                })
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isSubscribed ? "Unsubscribe from podcast" : "Subscribe to podcast")

                Button(action: { showMoreSheet = true }, label: {
                    Text("⋮")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                })
                .buttonStyle(.plain)
                .accessibilityLabel("More options")
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func episodeList(for podcast: PodcastDetailInfo) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(podcast.episodes.enumerated()), id: \.offset) { index, episode in
                EpisodeRowView(
                    episode: episode,
                    onTap: { playEpisode(episode, in: podcast) },
                    onNavigate: { pendingRoute = $0 }
                )

                if index < podcast.episodes.count - 1 {
                    Divider()
                        .padding(.leading, 100)
                }
            }
        }
    }

    // MARK: - Actions

    private func playAll(_ podcast: PodcastDetailInfo) {
        PlaybackQueue.play(podcast.episodes.map { $0.toSongItem() }, log: Log.podcastDetail, context: "playAll")
    }

    private func playEpisode(_ episode: EpisodeItem, in podcast: PodcastDetailInfo) {
        let songs = podcast.episodes.map { $0.toSongItem() }
        let song = episode.toSongItem()
        Task {
            let saved = await EpisodePlaybackStore.shared.position(for: episode.videoId)
            let resumeAt: TimeInterval? = if let saved, saved.position > 10, !saved.isFinished {
                saved.position
            } else {
                nil
            }
            PlaybackQueue.play(song, in: songs, log: Log.podcastDetail, context: "playEpisode")
            guard let resumeAt else { return }
            // Wait until this episode's file is actually loaded before seeking.
            // A fixed delay races slow stream resolves (BotGuard etc.): the seek
            // lands on the old file (or nothing) and the fresh load starts at 0.
            for _ in 0..<75 {
                try? await Task.sleep(for: .milliseconds(200))
                if PlayerController.shared.currentVideoId == episode.videoId { break }
            }
            guard PlayerController.shared.currentVideoId == episode.videoId else { return }
            PlayerController.shared.seek(to: resumeAt, isUserAction: false)
        }
    }
}

// MARK: - Podcast More Sheet

/// Overflow menu matching PlaylistMoreSheet, with Subscribe as the
/// first row (mirrors podcast.subscribed_at).
struct PodcastMoreSheet: View {
    let podcast: PodcastDetailInfo
    let isSubscribed: Bool
    var onToggleSubscribe: (() -> Void)?
    var onPlayAll: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome {
            MenuCard {
                MenuRow(
                    icon: isSubscribed ? "checkmark.circle.fill" : "plus.circle",
                    title: isSubscribed ? "Subscribed" : "Subscribe",
                    subtitle: isSubscribed ? "Unsubscribe from this podcast" : "Get new episodes in your library"
                ) {
                    onToggleSubscribe?()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "play.fill",
                    title: "Play All",
                    subtitle: "Play episodes from the top"
                ) {
                    onPlayAll?()
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
                    subtitle: "Download episodes for offline playback"
                ) {
                    downloadAll()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "square.and.arrow.up",
                    title: "Share",
                    subtitle: "Share this podcast with others"
                ) {
                    share()
                    dismiss()
                }
            }
        }
    }

    private func addToQueue() {
        let np = NowPlaying.shared
        np.queueSongs.append(contentsOf: podcast.episodes.map { $0.toSongItem() })
        np.persistQueueState()
    }

    private func downloadAll() {
        for episode in podcast.episodes {
            Task { await DownloadManager.shared.download(song: episode.toSongItem()) }
        }
    }

    private func share() {
        guard let url = URL(string: "https://music.youtube.com/browse/\(podcast.browseId)") else { return }
        presentShareSheet(items: [url])
        dismiss()
    }
}

// MARK: - Inline expandable description ("… More" right after the text)

/// Shows a truncated prefix with an inline tappable More suffix, expanding
/// to the full text with a Less suffix. The toggle sits immediately after
/// the text instead of on a separate row below it.
private struct ExpandableDescriptionText: View {
    let text: String
    var collapsedLimit: Int = 140
    var alignment: TextAlignment = .leading
    /// Tapping non-truncated text falls through here (e.g. play the episode).
    var onInactiveTap: (() -> Void)?

    @State private var expanded = false

    private var isTruncated: Bool { text.count > collapsedLimit }

    var body: some View {
        Text(styledText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .onTapGesture {
                if isTruncated {
                    expanded.toggle()
                } else {
                    onInactiveTap?()
                }
            }
            .accessibilityLabel(isTruncated ? (expanded ? "Show less" : "Show more") : "Description")
    }

    private var styledText: AttributedString {
        var str = AttributedString(displayText)
        guard isTruncated else { return str }
        var toggle = AttributedString(toggleLabel)
        toggle.foregroundColor = .accentColor
        toggle.font = .caption.weight(.semibold)
        str.append(toggle)
        return str
    }

    private var displayText: String {
        guard !expanded, isTruncated else { return text }
        return String(text.prefix(collapsedLimit)) + "… "
    }

    private var toggleLabel: String {
        guard isTruncated else { return "" }
        return expanded ? " Less" : "More"
    }
}

// MARK: - Episode row matching YouTube Music: thumbnail + title +
// description snippet + "views • date • duration" meta line.

private struct EpisodeRowView: View {
    let episode: EpisodeItem
    var onTap: () -> Void
    var onNavigate: ((DetailRoute) -> Void)?

    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var progress: Double = 0
    @State private var hasResume = false
    @State private var showMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImageView(url: episode.thumbnailUrl)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture(perform: onTap)

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .onTapGesture(perform: onTap)

                    if let desc = episode.descriptionText, !desc.isEmpty {
                        // Own tap handling (expand/collapse) so toggling More
                        // never starts playback; short text still plays.
                        ExpandableDescriptionText(
                            text: desc,
                            collapsedLimit: 110,
                            alignment: .leading,
                            onInactiveTap: onTap
                        )
                    }

                    HStack(spacing: 4) {
                        if downloadManager.isDownloaded(videoId: episode.videoId) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Downloaded")
                        }
                        Text(episode.metaLine)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .onTapGesture(perform: onTap)
                }

                Spacer(minLength: 0)

                MoreButton {
                    showMenu = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if hasResume {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemGray5))
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 100)
                .padding(.trailing, 16)
                .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showMenu) {
            SongMenuSheet(
                song: episode.toSongItem(),
                onNavigate: { onNavigate?($0) }
            )
        }
        .task(id: episode.videoId) {
            // Tracked progress drives the bar and auto-resume on tap.
            if let saved = await EpisodePlaybackStore.shared.position(for: episode.videoId),
               !saved.isFinished, saved.position > 10 {
                progress = saved.progress
                hasResume = true
            } else {
                hasResume = false
            }
        }
    }
}
