//
//  FullPlayerView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI

struct FullPlayerView: View {
    let onCollapse: () -> Void

    @Environment(SettingsStore.self) private var settings
    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared
    @State private var editingProgress: Float = 0
    @State private var isEditingSlider = false
    @State private var collapseOffset: CGFloat = 0

    @ObservedObject private var likeStore = LikeStore.shared
    private var isLiked: Bool {
        guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var pendingRoute: DetailRoute?
    @State private var showSongMenu = false
    @State private var showSleepTimer = false
    @State private var artworkEntryOffset: CGFloat = 0
    @State private var currentLyrics: [LyricLine] = []
    @State private var canvasDominantColors: [Color]?
    @Bindable private var sleepTimer = SleepTimerController.shared

    private var playerBackgroundColors: [Color] {
        canvasDominantColors ?? np.dominantColors
    }

    private var activeLyricText: String? {
        let synchronizedLines = currentLyrics.filter {
            $0.startTime != nil &&
                !$0.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· ")).isEmpty
        }
        guard let firstLine = synchronizedLines.first else { return nil }

        let lyricTime = np.currentTime + settings.lyricsOffsetSeconds
        return synchronizedLines.last { line in
            guard let startTime = line.startTime else { return false }
            return startTime <= lyricTime
        }?.text ?? firstLine.text
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = geometry.size.width < 375 ? 24 : 32
            let isCompact = geometry.size.height < 700

            ZStack {
                if np.isVideoMode && np.hasVideo {
                    Color.black
                        .ignoresSafeArea()
                } else if settings.playerBackgroundStyle == .solid {
                    Color.black
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [
                            playerBackgroundColors.first ?? Color(red: 0.15, green: 0.15, blue: 0.2),
                            playerBackgroundColors.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.8), value: playerBackgroundColors)
                    .overlay(alignment: .top) {
                        Circle()
                            .fill(playerBackgroundColors.first ?? .blue)
                            .frame(width: 400, height: 400)
                            .blur(radius: 120)
                            .opacity(0.45)
                            .offset(y: -150)
                            .allowsHitTesting(false)
                    }
                }

                if !showLyrics && !showQueue && !np.isVideoMode {
                    artwork
                        .frame(maxWidth: .infinity)
                        .frame(height: min(
                            (geometry.size.height + geometry.safeAreaInsets.top) * 0.58,
                            geometry.size.height * 0.66
                        ))
                        .compositingGroup()
                        .clipped()
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: 0.62),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .offset(y: -geometry.safeAreaInsets.top)
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                VStack(spacing: 0) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 36, height: 5)
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        .contentShape(Rectangle().size(width: 60, height: 30))
                        .onTapGesture {
                            guard showLyrics else { return }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showLyrics = false
                            }
                        }
                        .accessibilityLabel(showLyrics ? "Close lyrics" : "Collapse player")

                    if showLyrics {
                        LyricsView(
                            showLyrics: $showLyrics,
                            pendingRoute: $pendingRoute,
                            progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                        )
                    } else if np.isVideoMode && np.hasVideo {
                        musicVideoContent
                    } else if showQueue {
                        QueueView(
                            showQueue: $showQueue,
                            isShuffleOn: $np.isShuffleOn,
                            isRepeatOn: $np.isRepeatOn,
                            editingProgress: $editingProgress,
                            isEditingSlider: $isEditingSlider,
                            pendingRoute: $pendingRoute,
                            progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                        )
                    } else {
                        Color.clear.frame(height: isCompact ? 4 : 8)

                        Spacer(minLength: isCompact ? 8 : 16)

                        titleAndActionsRow
                            .padding(.horizontal, horizontalPadding)
                            .padding(.bottom, isCompact ? 10 : 14)

                        Group {
                            if let activeLyricText {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showLyrics = true
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(activeLyricText)
                                            .font(.system(size: 14, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    .foregroundStyle(.white.opacity(0.82))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, horizontalPadding)
                                .padding(.bottom, 8)
                                .accessibilityLabel("Current lyric: \(activeLyricText). Open lyrics")
                            } else {
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 33, alignment: .bottom)

                        progressSlider(horizontalPadding: horizontalPadding)
                            .padding(.top, 4)
                            .padding(.bottom, isCompact ? 8 : 12)

                        PlaybackControlsRow(
                            isPlaying: np.isPlaying,
                            hasPrevious: np.hasPrevious,
                            hasNext: np.hasNext,
                            onPrevious: { np.playPrevious() },
                            onPlayPause: { player.togglePlayPause() },
                            onNext: { np.playNext() }
                        )
                        .scaleEffect(isCompact ? 0.94 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: np.isPlaying)
                        .padding(.bottom, isCompact ? 2 : 8)

                        SecondaryActionsRow(
                            showQueue: $showQueue,
                            isRepeatOn: $np.isRepeatOn
                        )
                        .scaleEffect(isCompact ? 0.92 : 1)

                        Color.clear.frame(height: isCompact ? 2 : 8)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .offset(y: collapseOffset)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: collapseOffset)
            .animation(.easeInOut(duration: 0.35), value: showQueue)
            .simultaneousGesture(collapseDrag)
            .onChange(of: np.videoId) { _, _ in
                np.isVideoMode = false
                showLyrics = false
                showQueue = false
                preloadLyrics()
            }
            .onChange(of: np.queueSongs.count) { _, _ in
                np.preloadNeighborArtwork()
                preloadLyrics()
            }
            .onChange(of: np.queueIndex) { _, _ in
                np.preloadNeighborArtwork()
            }
            .onChange(of: showQueue) { _, newValue in
                if newValue { np.preloadNeighborArtwork() }
            }
            .task { np.preloadNeighborArtwork() }
            .task(id: np.videoId) { await loadCurrentLyrics() }
            .sheet(isPresented: $showSongMenu) {
                if let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil {
                    PlayerMenuSheet(song: song, onCollapseRequest: { onCollapse() })
                }
            }
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerSheet()
            }
            .background(
                Color.clear
                    .detailRouteSheet(item: $pendingRoute)
            )
        }
    }

    // MARK: - Gestures

    /// Swipe left/right on the artwork to skip tracks (toggleable in Settings).
    /// Blocked at the queue's ends (no movement); on skip, the incoming
    /// artwork slides in from the swipe direction.
    private var artworkSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard settings.artworkSwipeNavigation else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -60, np.hasNext {
                    np.playNext()
                    slideInArtwork(fromLeft: false)
                } else if value.translation.width > 60, np.hasPrevious {
                    np.playPrevious()
                    slideInArtwork(fromLeft: true)
                }
            }
    }

    private func slideInArtwork(fromLeft: Bool) {
        artworkEntryOffset = fromLeft ? -600 : 600
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            artworkEntryOffset = 0
        }
    }

    /// Swipe down anywhere to collapse. Vertical-dominant drags only.
    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else { return }
                collapseOffset = value.translation.height
            }
            .onEnded { value in
                defer { collapseOffset = 0 }
                let isVertical = value.translation.height > abs(value.translation.width)
                if isVertical, value.translation.height > 140 {
                    onCollapse()
                }
            }
    }

    // MARK: - Player Content

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    private func loadCurrentLyrics() async {
        guard let videoId = np.videoId else {
            currentLyrics = []
            return
        }
        currentLyrics = []
        guard let lines = try? await LyricsService.shared.fetchLyrics(videoId: videoId),
              !Task.isCancelled,
              np.videoId == videoId else { return }
        currentLyrics = lines
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PlayerTitleBlock(
                title: np.title,
                artist: np.displayArtist,
                spacing: 4,
                titleFont: .title3.weight(.bold),
                titleHeight: 28
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 8) {
                PlayerLikeButton(isLiked: isLiked) {
                    guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return }
                    Task { await likeStore.toggle(song: song) }
                }

                if sleepTimer.isActive {
                    Button {
                        showSleepTimer = true
                    } label: {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Sleep Timer")
                    .accessibilityValue(sleepTimer.statusText)
                }

                if np.queueSongs.indices.contains(np.queueIndex) {
                    PlayerOptionsButton {
                        showSongMenu = true
                    }
                }
            }
        }
    }

    private var musicVideoContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        np.isVideoMode = false
                        showQueue = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .accessibilityLabel("Return to artwork player")

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            musicVideoStage

            QueueView(
                showQueue: $showQueue,
                isShuffleOn: $np.isShuffleOn,
                isRepeatOn: $np.isRepeatOn,
                editingProgress: $editingProgress,
                isEditingSlider: $isEditingSlider,
                pendingRoute: $pendingRoute,
                progressSlider: { progressSlider(horizontalPadding: 32) },
                isVideoMode: true
            )
            .frame(maxHeight: .infinity)
        }
    }

    private var musicVideoStage: some View {
        artwork
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if np.isVideoMode, np.hasVideo {
                ZStack {
                    VideoPlayerView()
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.12),
                                    .init(color: .white, location: 0.95),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    if !np.isVideoReady {
                        artworkImage
                            .transition(.opacity)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .animation(.easeOut(duration: 0.2), value: np.isVideoReady)
            } else {
                ZStack {
                    artworkImage
                    CanvasVideoView(
                        videoId: np.videoId,
                        title: np.title,
                        artist: np.artist,
                        album: np.albumTitle.isEmpty ? nil : np.albumTitle,
                        isPlaying: np.isPlaying,
                        enabled: settings.canvasEnabled,
                        onDominantColorsChange: { canvasDominantColors = $0 }
                    )
                }
                .onTapGesture {
                    guard np.hasVideo else { return }
                    showQueue = true
                    player.setVideoMode()
                }
            }
        }
        .offset(x: artworkEntryOffset)
        .gesture(artworkSwipe)
    }

    /// Song artwork (or placeholder), filling its container.
    private var artworkImage: some View {
        ZStack {
            if let uiImage = np.thumbnailUIImage {
                let cropped = uiImage.centerCroppedSquare()
                GeometryReader { geo in
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private func progressSlider(horizontalPadding: CGFloat) -> some View {
        VStack(spacing: 6) {
            ProgressBar(
                progress: Binding(
                    get: { isEditingSlider ? editingProgress : np.progress },
                    set: { editingProgress = $0 }
                ),
                accentColor: np.dominantColors.first ?? .white,
                isPlaying: np.isPlaying,
                onEditingChanged: { editing in
                    if editing {
                        editingProgress = np.progress
                    } else {
                        let target = TimeInterval(editingProgress) * np.duration
                        player.seek(to: target)
                        np.currentTime = target
                        player.updateNowPlayingProgress()
                    }
                    isEditingSlider = editing
                }
            )

            HStack {
                Text(DurationFormat.playbackTime(isEditingSlider
                    ? TimeInterval(editingProgress) * np.duration
                    : np.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Text(DurationFormat.playbackTime(np.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, horizontalPadding)
    }

}
