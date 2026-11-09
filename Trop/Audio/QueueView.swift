//
//  QueueView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI

struct QueueView<ProgressSlider: View>: View {
    private let np = NowPlaying.shared
    private let player = PlayerController.shared
    @ObservedObject private var likeStore = LikeStore.shared

    @Binding var showQueue: Bool
    @Binding var isShuffleOn: Bool
    @Binding var isRepeatOn: Bool
    @Binding var editingProgress: Float
    @Binding var isEditingSlider: Bool
    let pendingRoute: Binding<DetailRoute?>
    @ViewBuilder var progressSlider: () -> ProgressSlider
    var isVideoMode: Bool = false

    @State private var showSongMenu = false

    var body: some View {
        queueContent
            .simultaneousGesture(backSwipeGesture)
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard value.startLocation.x <= 28,
                      isHorizontal,
                      value.translation.width > 80 else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    if isVideoMode {
                        np.isVideoMode = false
                        showQueue = false
                    } else {
                        showQueue = false
                    }
                }
            }
    }

    // MARK: - Queue Content

    private var queueContent: some View {
        VStack(spacing: 0) {
            if !isVideoMode {
                queueHeader
                    .padding(.horizontal, 20)
                playbackPillsRow
            }

            queueListHeaderRow

            ScrollViewReader { proxy in
                List {
                    if np.queueSongs.isEmpty {
                        emptyQueueRow
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(Array(np.queueSongs.enumerated()), id: \.element.videoId) { index, song in
                            queueRow(song: song, index: index)
                        }
                        .onMove(perform: np.moveQueueSongs)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.colorScheme, .dark)
                .scrollIndicators(.hidden)
                .layoutPriority(1)
                .onAppear {
                    if np.queueSongs.indices.contains(np.queueIndex) {
                        proxy.scrollTo(np.queueSongs[np.queueIndex].videoId, anchor: .center)
                    }
                }
            }

            if isVideoMode {
                playbackPillsRow
                PlayerTransportAirPlayFooter(
                    isPlaying: np.isPlaying,
                    hasPrevious: np.hasPrevious,
                    hasNext: np.hasNext,
                    onPrevious: { np.playPrevious() },
                    onPlayPause: { player.togglePlayPause() },
                    onNext: { np.playNext() }
                )
            } else {
                VStack(spacing: 16) {
                    progressSlider()
                        .padding(.top, 16)

                    PlaybackControlsRow(
                        isPlaying: np.isPlaying,
                        hasPrevious: np.hasPrevious,
                        hasNext: np.hasNext,
                        onPrevious: { np.playPrevious() },
                        onPlayPause: { player.togglePlayPause() },
                        onNext: { np.playNext() }
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: np.isPlaying)

                    SecondaryActionsRow(
                        showQueue: $showQueue,
                        isRepeatOn: $isRepeatOn
                    )
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Queue Header

    private var queueHeader: some View {
        HStack(spacing: 12) {
            if let uiImage = np.thumbnailUIImage {
                let cropped = uiImage.centerCroppedSquare()
                Image(uiImage: cropped)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 64, height: 64)
            }

            PlayerTitleBlock(title: np.title, artist: np.displayArtist)

            Spacer()

            if let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil {
                PlayerLikeButton(isLiked: likeStore.isLiked(videoId: song.videoId)) {
                    Task { await likeStore.toggle(song: song) }
                }
                PlayerOptionsButton(color: .white.opacity(0.6)) {
                    showSongMenu = true
                }
                .sheet(isPresented: $showSongMenu) {
                    SongMenuSheet(
                        song: song,
                        onNavigate: { pendingRoute.wrappedValue = $0 }
                    )
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                showQueue = false
            }
        }
    }

    // MARK: - Queue Sub-Views

    private var playbackPillsRow: some View {
        HStack(spacing: 8) {
            pillButton(isOn: $isShuffleOn, icon: "shuffle") {
                if isShuffleOn {
                    np.shuffleQueue()
                } else {
                    np.disableShuffle()
                }
            }
            pillButton(isOn: $isRepeatOn, icon: "repeat")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func pillButton(isOn: Binding<Bool>, icon: String, action: (() -> Void)? = nil) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    Capsule()
                        .fill(isOn.wrappedValue ? .white.opacity(0.15) : .white.opacity(0.07))
                )
        }
    }

    private var queueListHeaderRow: some View {
        HStack {
            Text("Queue")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .textCase(.uppercase)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var emptyQueueRow: some View {
        HStack {
            Spacer()
            Text("Queue is empty")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func queueRow(song: SongItem, index: Int) -> some View {
        let isCurrent = index == np.queueIndex

        return Button {
            playSong(at: index)
        } label: {
            QueueSongRow(
                song: song,
                isCurrent: isCurrent,
                isPlayed: index < np.queueIndex
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(
            Group {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                        .padding(.horizontal, 12)
                }
            }
        )
        .listRowSeparator(.hidden)
        .onDrag {
            NSItemProvider(object: song.videoId as NSString)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.3)) {
                    removeSong(at: index)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func playSong(at index: Int) {
        guard np.queueSongs.indices.contains(index) else { return }
        np.lastManualSkipTime = Date()
        PlayerController.shared.cancelCrossfade()
        np.queueIndex = index
        np.playCurrentSong(logContext: "resolveAndPlay", manageResolvingFlag: false)
    }

    private func removeSong(at index: Int) {
        guard np.queueSongs.indices.contains(index) else { return }
        let wasCurrent = index == np.queueIndex
        let removedVideoId = np.queueSongs[index].videoId
        np.queueSongs.remove(at: index)
        if wasCurrent {
            PlayerController.shared.cancelCrossfade()
            if np.queueSongs.isEmpty {
                np.queueIndex = 0
                np.isPlaying = false
                np.persistQueueState()
                Task { @MainActor in PlayerController.shared.setPaused(true) }
                return
            }
            let nextIndex = min(index, np.queueSongs.count - 1)
            np.queueIndex = nextIndex
            let song = np.queueSongs[nextIndex]
            np.update(with: song)
            loggedTask(Log.nowPlaying, "removeSong auto-play failed") {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId)
            }
        } else {
            np.repairQueueIndex()
        }
        np.persistQueueState()
        if !wasCurrent && removedVideoId == np.videoId {
            np.repairQueueIndex()
        }
    }
}

// MARK: - Queue Song Row

struct QueueSongRow: View {
    let song: SongItem
    var isCurrent = false
    var isPlayed = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: song.thumbnailUrl)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isPlayed ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    text: song.title,
                    font: .subheadline.weight(isCurrent ? .semibold : .medium),
                    frameHeight: 20,
                    textColor: titleColor
                )

                let artistStr = song.artists.map(\.name).joined(separator: ", ")
                if !artistStr.isEmpty {
                    Text(artistStr)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(isPlayed ? 0.35 : 0.6))
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }

    private var titleColor: Color {
        isPlayed && !isCurrent ? Color.white.opacity(0.45) : .white
    }
}
