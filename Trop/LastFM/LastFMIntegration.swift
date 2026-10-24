//
//  LastFMIntegration.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation
import Combine
import UIKit

@MainActor
final class LastFMIntegration {
    static let shared = LastFMIntegration()

    private var cancellables = Set<AnyCancellable>()
    private var periodicTask: Task<Void, Never>?
    private var scrobbleJob: Task<Void, Never>?
    private var scrobbleRemainingMillis: Int64 = 0
    private var scrobbleTimerStartedAtMs: Int64 = 0
    private var songStartedAtSec: Int64 = 0
    private var songStarted = false
    private var currentVideoId: String?
    private var currentSong: SongItem?
    private var lastScrobbledVideoId: String?

    private init() {}

    // MARK: - Public

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: LastFMDefaults.scrobblingEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: LastFMDefaults.scrobblingEnabledKey) }
    }

    var isLoggedIn: Bool { LastFMTokenStore.shared.retrieveSessionKey() != nil }

    func start() {
        // Observe NowPlaying via periodic polling + playState publisher
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.syncState()
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNowPlayingChanged), name: .nowPlayingDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppForeground), name: UIApplication.didBecomeActiveNotification, object: nil)

        PlayerController.shared.playState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    let isPlaying = state == .playing
                    self.handlePlayState(isPlaying: isPlaying)
                }
            }
            .store(in: &cancellables)

        // Listen for likes if needed (via Notification)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLikeNotification(_:)), name: .lastFMLikeChanged, object: nil)
    }

    @objc private func handleNowPlayingChanged() { Task { await syncState() } }
    @objc private func handleAppForeground() { Task { await syncState() } }

    @objc private func handleLikeNotification(_ note: Notification) {
        guard let info = note.userInfo,
              let artist = info["artist"] as? String,
              let track = info["track"] as? String,
              let love = info["love"] as? Bool else { return }
        guard UserDefaults.standard.bool(forKey: LastFMDefaults.useSendLikesKey) else { return }
        guard isLoggedIn, isEnabled else { return }
        Task {
            try? await LastFMService.shared.setLoveStatus(artist: artist, track: track, love: love)
        }
    }

    private func handlePlayState(isPlaying: Bool) {
        guard let vid = NowPlaying.shared.videoId, vid == currentVideoId else { return }
        if isPlaying {
            if !songStarted {
                // edge: started without songStarted
                if let song = currentSong {
                    onSongStart(song: song, duration: NowPlaying.shared.duration)
                }
            } else {
                onSongResume()
            }
        } else {
            onSongPause()
        }
    }

    // MARK: - Sync

    func syncState() async {
        guard isEnabled else { return }
        guard LastFMTokenStore.shared.retrieveSessionKey() != nil else { return }

        guard let videoId = NowPlaying.shared.videoId else {
            onSongStop()
            currentVideoId = nil
            currentSong = nil
            return
        }

        // Check if song changed
        if videoId != currentVideoId {
            onSongStop()
            guard let song = NowPlaying.shared.queueSongs.first(where: { $0.videoId == videoId }) else {
                // Fallback to NowPlaying title/artist
                let fallback = SongItem(
                    videoId: videoId,
                    title: NowPlaying.shared.title,
                    artists: NowPlaying.shared.artists,
                    album: NowPlaying.shared.albumTitle.isEmpty ? nil : NowPlaying.shared.albumTitle,
                    albumId: nil,
                    duration: Int(NowPlaying.shared.duration),
                    thumbnailUrl: nil,
                    isExplicit: false,
                    playlistId: nil,
                    likeStatus: nil
                )
                currentVideoId = videoId
                currentSong = fallback
                onSongStart(song: fallback, duration: NowPlaying.shared.duration)
                return
            }
            currentVideoId = videoId
            currentSong = song
            onSongStart(song: song, duration: NowPlaying.shared.duration > 0 ? NowPlaying.shared.duration : TimeInterval(song.duration))
        } else {
            // Same song, keep play/pause in sync via playState publisher; periodic ensures resume after track change not missed
        }
    }

    // MARK: - Scrobble lifecycle (mirrors ScrobbleManager.kt)

    private var minSongDuration: Int {
        UserDefaults.standard.object(forKey: LastFMDefaults.scrobbleMinDurationKey) as? Int ?? LastFMDefaults.defaultScrobbleMinDuration
    }
    private var scrobbleDelayPercent: Float {
        if let v = UserDefaults.standard.object(forKey: LastFMDefaults.scrobbleDelayPercentKey) as? Double {
            return Float(v)
        }
        if let f = UserDefaults.standard.object(forKey: LastFMDefaults.scrobbleDelayPercentKey) as? Float {
            return f
        }
        return LastFMDefaults.defaultScrobbleDelayPercent
    }
    private var scrobbleDelaySeconds: Int {
        UserDefaults.standard.object(forKey: LastFMDefaults.scrobbleDelaySecondsKey) as? Int ?? LastFMDefaults.defaultScrobbleDelaySeconds
    }
    private var useNowPlaying: Bool {
        UserDefaults.standard.object(forKey: LastFMDefaults.useNowPlayingKey) as? Bool ?? false
    }

    private func onSongStart(song: SongItem, duration: TimeInterval?) {
        let durationSec = Int(duration ?? TimeInterval(song.duration))
        if durationSec <= minSongDuration {
            if useNowPlaying { updateNowPlaying(song: song) }
            return
        }

        songStartedAtSec = Int64(Date().timeIntervalSince1970)
        songStarted = true

        scrobbleJob?.cancel()
        let thresholdMs = Int64(Float(durationSec) * 1000 * scrobbleDelayPercent)
        scrobbleRemainingMillis = min(thresholdMs, Int64(scrobbleDelaySeconds * 1000))

        if scrobbleRemainingMillis <= 0 {
            scrobbleSong(song: song)
            return
        }
        scrobbleTimerStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let remaining = scrobbleRemainingMillis
        let capturedSong = song
        scrobbleJob = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.scrobbleSong(song: capturedSong) }
            await MainActor.run { self?.scrobbleJob = nil }
        }

        if useNowPlaying {
            updateNowPlaying(song: song)
        }
    }

    private func onSongPause() {
        scrobbleJob?.cancel()
        if scrobbleTimerStartedAtMs != 0 {
            let elapsed = Int64(Date().timeIntervalSince1970 * 1000) - scrobbleTimerStartedAtMs
            scrobbleRemainingMillis -= elapsed
            if scrobbleRemainingMillis < 0 { scrobbleRemainingMillis = 0 }
            scrobbleTimerStartedAtMs = 0
        }
    }

    private func onSongResume() {
        if scrobbleRemainingMillis <= 0 { return }
        scrobbleJob?.cancel()
        scrobbleTimerStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let remaining = scrobbleRemainingMillis
        guard let song = currentSong else { return }
        let capturedSong = song
        scrobbleJob = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.scrobbleSong(song: capturedSong) }
            await MainActor.run { self?.scrobbleJob = nil }
        }
    }

    private func onSongStop() {
        scrobbleJob?.cancel()
        scrobbleJob = nil
        scrobbleRemainingMillis = 0
        scrobbleTimerStartedAtMs = 0
        songStartedAtSec = 0
        songStarted = false
    }

    private func scrobbleSong(song: SongItem) {
        let artist = song.artists.map(\.name).joined(separator: ", ")
        let track = song.title
        let album = song.album
        let duration = song.duration
        let ts = songStartedAtSec
        guard !artist.isEmpty, !track.isEmpty else { return }
        if lastScrobbledVideoId == song.videoId { return }
        lastScrobbledVideoId = song.videoId
        Task {
            do {
                try await LastFMService.shared.scrobble(
                    artist: artist, track: track, timestamp: ts,
                    album: album, trackNumber: nil, duration: duration > 0 ? duration : nil
                )
            } catch {
                await MainActor.run { self.lastScrobbledVideoId = nil }
            }
        }
    }

    private func updateNowPlaying(song: SongItem) {
        let artist = song.artists.map(\.name).joined(separator: ", ")
        let track = song.title
        guard !artist.isEmpty, !track.isEmpty else { return }
        Task {
            try? await LastFMService.shared.updateNowPlaying(
                artist: artist, track: track, album: song.album,
                trackNumber: nil, duration: song.duration > 0 ? song.duration : nil
            )
        }
    }

    func handleLove(artist: String, track: String, love: Bool) async {
        guard UserDefaults.standard.bool(forKey: LastFMDefaults.useSendLikesKey) else { return }
        guard isEnabled, isLoggedIn else { return }
        guard !artist.isEmpty, !track.isEmpty else { return }
        try? await LastFMService.shared.setLoveStatus(artist: artist, track: track, love: love)
    }

    func logout() {
        LastFMTokenStore.shared.clear()
        onSongStop()
        currentVideoId = nil
        currentSong = nil
        lastScrobbledVideoId = nil
    }
}
