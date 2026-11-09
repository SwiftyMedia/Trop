//
//  LyricsView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI

struct LyricsView<ProgressSlider: View>: View {
    private let np = NowPlaying.shared
    private let player = PlayerController.shared
    @Environment(SettingsStore.self) private var settings

    @Binding var showLyrics: Bool
    let pendingRoute: Binding<DetailRoute?>
    @ViewBuilder var progressSlider: () -> ProgressSlider

    @ObservedObject private var likeStore = LikeStore.shared
    @State private var lines: [LyricLine] = []
    @State private var activeIndex: Int = 0
    @State private var displayTime: TimeInterval = 0
    @State private var showSongMenu = false
    @State private var instrumentalGaps: [InstrumentalGap] = []
    @State private var romanizedLines: [String?] = []

    struct InstrumentalGap {
        let afterIndex: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    // MARK: - Auto-scroll & Re-sync

    @State private var isAutoScrollEnabled = true
    @State private var userHasScrolled = false
    @State private var hasPositionedInitialLyrics = false
    @State private var scrollProxy: ScrollViewProxy?

    private var isLiked: Bool {
        guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            songInfoRow

            lyricsBody
                .layoutPriority(1)

            playbackControls
        }
        .ignoresSafeArea(edges: .bottom)
        .simultaneousGesture(swipeBackGesture)
        .sheet(isPresented: $showSongMenu) {
            LyricsMenuSheet()
        }
        .task(id: np.videoId) { await loadLyrics() }
        .onChange(of: np.currentTime) { _, _ in updateActiveLine() }
        .onChange(of: settings.lyricsOffsetSeconds) { _, _ in updateActiveLine() }
        .onChange(of: settings.romanizeCurrentTrack) { _, _ in
            Task { await rebuildRomanization() }
        }
        .onChange(of: LyricsState.shared.refreshToken) { _, _ in
            Task { await loadLyrics() }
        }
        .task { await runDisplayTimer() }
    }

    // MARK: - Header

    private var headerBar: some View {
        Color.clear
            .padding(.top, 16)
    }

    private var swipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard value.startLocation.x <= 28,
                      isHorizontal,
                      value.translation.width > 80 else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    showLyrics = false
                }
            }
    }

    // MARK: - Lyrics Body

    private var lyricsBody: some View {
        Group {
            if lines.isEmpty {
                EmptyView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                lyricsContentView
            }
        }
    }

    // MARK: - Lyrics Content

    private var lyricsContentView: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: settings.lyricsAlignment.textAlignment.horizontal, spacing: 18) {
                            Spacer().frame(height: 20)

                            if let provider = LyricsState.shared.providerName {
                                Text("Lyrics from \(provider)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(maxWidth: .infinity, alignment: settings.lyricsAlignment.textAlignment)
                                    .padding(.horizontal, 24)
                            }

                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                lyricsLineRow(index: index, line: line)
                                    .id(line.id)
                            }

                            Spacer().frame(height: geo.size.height * 0.38)
                        }
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .tracking || newPhase == .interacting {
                            pauseAutoScroll()
                        }
                    }
                    .onAppear { scrollProxy = proxy }
                    .onChange(of: activeIndex) { _, newIndex in
                        guard lines.indices.contains(newIndex) else { return }
                        if isAutoScrollEnabled && !userHasScrolled {
                            if hasPositionedInitialLyrics {
                                scrollToActive()
                            } else {
                                hasPositionedInitialLyrics = true
                            }
                        }
                    }
                }
            }

            if userHasScrolled && !lines.isEmpty {
                resyncButton
            }
        }
    }

    // MARK: - Re-sync Button

    private var resyncButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                userHasScrolled = false
                isAutoScrollEnabled = true
            }
            scrollToActive()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                Text("Re-sync")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.white.opacity(0.15)))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.bottom, 16)
    }

    // MARK: - Scrolling

    private func pauseAutoScroll() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isAutoScrollEnabled = false
            userHasScrolled = true
        }
    }

    private func resumeAutoScroll() {
        isAutoScrollEnabled = true
        userHasScrolled = false
        scrollToActive()
    }

    /// Centers the active line via the proxy only — writing the
    /// scrollPosition binding here would top-align the line and fight the
    /// center anchor.
    private func scrollToActive() {
        guard lines.indices.contains(activeIndex) else { return }
        let targetID = lines[activeIndex].id
        withAnimation(.easeInOut(duration: 0.4)) {
            scrollProxy?.scrollTo(targetID, anchor: .center)
        }
    }

    // MARK: - Distance-based Opacity & Scale (Metrolist-style)

    private func opacityForDistance(_ distance: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1: return 0.7
        case 2: return 0.55
        default: return 0.4
        }
    }

    private func scaleForDistance(_ distance: Int) -> CGFloat {
        switch distance {
        case 0: return 1
        case 1: return 0.97
        default: return 0.94
        }
    }

    // MARK: - Interval Indicator (instrumental gaps)

    /// A lyric line plus its interval ring, which only exists in the hierarchy
    /// while playback is actually inside the gap.
    private func lyricsLineRow(index: Int, line: LyricLine) -> some View {
        let gap = instrumentalGaps.last(where: { $0.afterIndex == index })
        let showRing = settings.showIntervalIndicator && gap != nil && isVisibleInGap(gap!)
        let romanized = romanization(for: index)
        let useWordHighlight = settings.wordByWordLyrics
            && index == activeIndex
            && line.hasWordTimings

        return VStack(spacing: 0) {
            LyricsLineView(
                text: line.text,
                isActive: index == activeIndex,
                alignment: settings.lyricsAlignment,
                fontSize: settings.lyricsFontSize,
                lineOpacity: index == activeIndex ? 1 : opacityForDistance(abs(index - activeIndex)),
                lineScale: index == activeIndex ? 1 : scaleForDistance(abs(index - activeIndex)),
                romanizedText: romanized,
                words: useWordHighlight ? line.words : nil,
                playbackTime: displayTime + settings.lyricsOffsetSeconds,
                onTap: {
                    if let t = line.startTime {
                        player.seek(to: t)
                        np.currentTime = t
                        resumeAutoScroll()
                    }
                }
            )

            if showRing, let gap {
                IntervalIndicatorView(
                    start: gap.start,
                    end: gap.end - 0.65,
                    now: displayTime + settings.lyricsOffsetSeconds,
                    color: intervalIndicatorColor
                )
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showRing)
    }

    /// Metrolist's expressiveAccent: white on dynamic (album art) backgrounds,
    /// the accent color on solid ones.
    private var intervalIndicatorColor: Color {
        switch settings.playerBackgroundStyle {
        case .solid: return settings.accentColor
        case .dynamic: return .white
        }
    }

    /// The romanized variant for a line, when the toggle is on and one exists.
    private func romanization(for index: Int) -> String? {
        guard settings.romanizeCurrentTrack,
              romanizedLines.indices.contains(index) else { return nil }
        return romanizedLines[index]
    }

    /// Blank / ♪-only timestamped lines declare instrumental spans.
    private static func isInstrumentalMarker(_ line: LyricLine) -> Bool {
        line.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· "))
            .isEmpty
    }

    /// Mirrors Metrolist's updateMergedList: an interval ring is created only
    /// from positive evidence — a blank interlude marker whose timestamp says
    /// the words already ended. Nothing is estimated, so the ring never shows
    /// over actual singing.
    private func detectGaps(in all: [LyricLine]) -> [InstrumentalGap] {
        var displayIndices = [Int?](repeating: nil, count: all.count)
        var displayCount = 0
        for (i, line) in all.enumerated() where !Self.isInstrumentalMarker(line) {
            displayIndices[i] = displayCount
            displayCount += 1
        }

        var gaps: [InstrumentalGap] = []
        for (i, marker) in all.enumerated() {
            guard Self.isInstrumentalMarker(marker), let gapStart = marker.startTime else { continue }

            // Attach to the nearest preceding vocal line; intro markers have none.
            var afterIndex: Int?
            var j = i - 1
            while j >= 0, afterIndex == nil {
                afterIndex = displayIndices[j]
                j -= 1
            }
            guard let afterIndex else { continue }

            // The break ends when the next lyrics start.
            var nextStart: TimeInterval?
            var k = i + 1
            while k < all.count, nextStart == nil {
                nextStart = all[k].startTime
                k += 1
            }
            guard let gapEnd = nextStart, gapEnd - gapStart > 4 else { continue }

            gaps.append(InstrumentalGap(afterIndex: afterIndex, start: gapStart, end: gapEnd))
        }
        return gaps
    }

    /// The ring disappears slightly before vocals resume, like Metrolist's -650ms.
    private func isVisibleInGap(_ gap: InstrumentalGap) -> Bool {
        let t = displayTime + settings.lyricsOffsetSeconds
        return t >= gap.start && t <= gap.end - 0.65
    }

    // MARK: - Romanization

    /// Transliterates lines off the main actor when the toggle is on.
    private func rebuildRomanization() async {
        guard settings.romanizeCurrentTrack, !lines.isEmpty else {
            romanizedLines = []
            return
        }
        let texts = lines.map(\.text)
        romanizedLines = await Task.detached(priority: .userInitiated) {
            texts.map { LyricsRomanizer.romanize($0) }
        }.value
    }

    /// Fires on an adaptive cadence so letter-sync stays smooth while playing
    private func runDisplayTimer() async {
        while !Task.isCancelled {
            let playing = np.isPlaying
            let hasSynced = lines.contains { $0.startTime != nil }
            let interval: UInt64 = (playing && hasSynced) ? 120_000_000 : 500_000_000
            let t = np.currentTime
            if t != displayTime { displayTime = t }
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    // MARK: - Shared Song Info Row

    private var songInfoRow: some View {
        HStack(spacing: 12) {
            if let uiImage = np.thumbnailUIImage {
                Image(uiImage: uiImage.centerCroppedSquare())
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

            PlayerLikeButton(
                isLiked: isLiked,
                fontSize: 18
            ) {
                guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return }
                Task { await likeStore.toggle(song: song) }
            }

            if np.queueSongs.indices.contains(np.queueIndex) {
                PlayerOptionsButton(color: .white.opacity(0.6)) {
                    showSongMenu = true
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var playbackControls: some View {
        VStack(spacing: 6) {
            progressSlider()

            PlayerPlayPauseButton(isPlaying: np.isPlaying) {
                player.togglePlayPause()
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: np.isPlaying)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    // MARK: - Data

    private func loadLyrics() async {
        guard let videoId = np.videoId else {
            lines = []
            return
        }
        lines = []
        instrumentalGaps = []
        activeIndex = 0
        hasPositionedInitialLyrics = false
        isAutoScrollEnabled = true
        userHasScrolled = false
        LyricsState.shared.providerName = nil

        guard !Task.isCancelled else { return }
        do {
            let result = try await LyricsService.shared.fetchLyrics(videoId: videoId)
            guard !result.isEmpty else { return }
            let withoutMarkers = result.filter { !Self.isInstrumentalMarker($0) }
            lines = withoutMarkers.isEmpty ? result : withoutMarkers
            instrumentalGaps = detectGaps(in: result)
            updateActiveLine()
            await rebuildRomanization()
        } catch {
        }
    }

    private func updateActiveLine() {
        guard !lines.isEmpty else { return }
        let t = np.currentTime + settings.lyricsOffsetSeconds
        var idx = 0
        for (i, line) in lines.enumerated() {
            guard let start = line.startTime else { continue }
            if start <= t {
                idx = i
            } else {
                break
            }
        }
        if idx != activeIndex {
            activeIndex = idx
        }
    }
}

// MARK: - Interval Indicator Ring

/// Circular progress ring shown during instrumental gaps — SwiftUI take on
/// Metrolist's wavy ring: colored stroke over a 20% track.
///
/// Instead of stepping with playback-position updates (which arrive in coarse
/// chunks), the sweep is one continuous linear animation timed to finish
/// exactly when the gap ends; playback seeks re-anchor it.
private struct IntervalIndicatorView: View {
    let start: TimeInterval
    let end: TimeInterval
    let now: TimeInterval
    let color: Color

    @State private var displayedProgress: Double
    @State private var anchorNow: TimeInterval

    init(start: TimeInterval, end: TimeInterval, now: TimeInterval, color: Color) {
        self.start = start
        self.end = end
        self.now = now
        self.color = color
        _displayedProgress = State(initialValue: Self.fraction(at: now, start: start, end: end))
        _anchorNow = State(initialValue: now)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, min(1, displayedProgress))))
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 36, height: 36)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .onAppear { animateToCompletion() }
        .onChange(of: now) { _, newNow in
            // Position ticks are small; anything larger is a seek — re-anchor
            // the sweep so it still completes exactly on time.
            if abs(newNow - anchorNow) > 0.75 {
                anchorNow = newNow
                displayedProgress = Self.fraction(at: newNow, start: start, end: end)
                animateToCompletion(at: newNow)
            } else {
                anchorNow = newNow
            }
        }
    }

    private static func fraction(at t: TimeInterval, start: TimeInterval, end: TimeInterval) -> Double {
        guard end > start else { return 1 }
        return min(1, max(0, (t - start) / (end - start)))
    }

    private func animateToCompletion(at reference: TimeInterval? = nil) {
        let remaining = max(0.15, end - (reference ?? now))
        displayedProgress = min(displayedProgress, 0.999)
        withAnimation(.linear(duration: remaining).delay(0)) {
            displayedProgress = 1
        }
    }
}

// MARK: - Lyrics Line View

private struct LyricsLineView: View {
    let text: String
    let isActive: Bool
    let alignment: LyricsAlignment
    let fontSize: Double
    var lineOpacity: Double = 1
    var lineScale: CGFloat = 1
    /// Romanized variant rendered under the main line, Metrolist-style.
    var romanizedText: String?
    /// When set with playbackTime, renders karaoke-style word highlighting.
    var words: [LyricWord]? = nil
    var playbackTime: TimeInterval = 0
    let onTap: () -> Void

    private var activeWordIndex: Int? {
        guard let words, !words.isEmpty else { return nil }
        var idx = 0
        for (i, word) in words.enumerated() {
            if word.startTime <= playbackTime {
                idx = i
            } else {
                break
            }
        }
        return idx
    }

    var body: some View {
        let textToDisplay = text.isEmpty ? "\u{266A}" : text

        Button(action: onTap) {
            VStack(alignment: alignment.textAlignment.horizontal, spacing: 4) {
                if let words, isActive, words.count >= 2 {
                    wordHighlightText(words: words)
                        .multilineTextAlignment(alignment.multilineTextAlignment)
                } else {
                    Text(textToDisplay)
                        .font(.system(size: fontSize, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(alignment.multilineTextAlignment)
                }

                if let romanizedText, !romanizedText.isEmpty {
                    Text(romanizedText)
                        .font(.system(size: max(12, fontSize * 0.55), weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(alignment.multilineTextAlignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment.textAlignment)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(lineOpacity)
        .scaleEffect(lineScale, anchor: alignment.textAlignment == .leading ? .leading : alignment.textAlignment == .trailing ? .trailing : .center)
        .animation(.easeInOut(duration: 0.3), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: activeWordIndex)
    }

    /// Karaoke highlight: current word bright/bold, past slightly softer, upcoming dim.
    private func wordHighlightText(words: [LyricWord]) -> Text {
        let current = activeWordIndex ?? 0
        var result = Text("")
        for (i, word) in words.enumerated() {
            let piece: Text
            if i == current {
                piece = Text(word.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white)
            } else if i < current {
                piece = Text(word.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.78))
            } else {
                piece = Text(word.text)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.38))
            }
            result = result + piece
        }
        return result
    }
}
