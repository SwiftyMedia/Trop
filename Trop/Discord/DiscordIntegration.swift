//
//  DiscordIntegration.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation
import Combine
import UIKit

@MainActor
final class DiscordIntegration {
    static let shared = DiscordIntegration()

    private var cancellables = Set<AnyCancellable>()
    private var periodicTask: Task<Void, Never>?
    private var lastReconnectAttemptMs: Int64 = 0
    private var intentionalDisconnect = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enable) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enable); handleToggle(enabled: newValue) }
    }

    private enum Keys {
        static let enable = "discordRPCEnable"
    }

    private init() {}

    func start() {
        DiscordRpcManager.shared.initializeIfNeeded()

        // Observe toggle
        UserDefaults.standard.publisher(for: \.discordRPCEnableValue)
            .sink { [weak self] enabled in
                self?.handleToggle(enabled: enabled)
            }
            .store(in: &cancellables)

        // Observe NowPlaying publisher via Notification? Poll NowPlaying changes
        // Hook into periodic polling and NowPlaying timerTick via observation
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.syncDiscordState()
            }
        }

        // Observe NowPlaying changes (isPlaying / videoId)
        // Use NotificationCenter from NowPlaying? We'll use Combine timer + manual trigger
        NotificationCenter.default.addObserver(
            self, selector: #selector(didChangeNowPlaying), name: .nowPlayingDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        // Observe connectionStatus
        DiscordRpcManager.shared.connectionStatus
            .sink { [weak self] status in
                if status == .connected { Task { @MainActor in await self?.syncDiscordState() } }
            }
            .store(in: &cancellables)

        DiscordRpcManager.shared.settingsChanged
            .sink { [weak self] _ in Task { @MainActor in await self?.syncDiscordState() } }
            .store(in: &cancellables)
    }

    @objc private func didChangeNowPlaying() { Task { await syncDiscordState() } }
    @objc private func handleAppForeground() { Task { await syncDiscordState() } }
    @objc private func handleAppBackground() {
        // After 10 min screen off, disconnect if not playing — handled by system background? Keep simple: do nothing
    }

    private func handleToggle(enabled: Bool) {
        if enabled {
            intentionalDisconnect = false
            if DiscordRpcManager.shared.isReady() {
                Task { await syncDiscordState() }
            } else if let token = DiscordRpcManager.shared.getAccessToken() {
                DiscordRpcManager.shared.reconnectWithToken(token)
            }
        } else {
            if DiscordRpcManager.shared.isReady() {
                DiscordRpcManager.shared.disconnect()
                intentionalDisconnect = true
            }
        }
    }

    @MainActor
    func syncDiscordState() async {
        guard isEnabled else { return }
        guard let videoId = NowPlaying.shared.videoId else {
            DiscordRpcManager.shared.clear()
            return
        }
        if !DiscordRpcManager.shared.isReady() {
            if intentionalDisconnect { return }
            guard let token = DiscordRpcManager.shared.getAccessToken() else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if now - lastReconnectAttemptMs > 30_000 {
                lastReconnectAttemptMs = now
                DiscordRpcManager.shared.reconnectWithToken(token)
            }
            return
        }
        let isPlaying = NowPlaying.shared.isPlaying
        if DiscordRpcManager.shared.isShowingSong(songId: videoId, isPlaying: isPlaying),
           !DiscordRpcManager.shared.shouldRefreshActivityTiming() { return }
        guard let song = NowPlaying.shared.queueSongs.first(where: { $0.videoId == videoId }) else { return }
        await updateDiscordRPC(song: song, isPlaying: isPlaying)
    }

    @MainActor
    private func updateDiscordRPC(song: SongItem, isPlaying: Bool) async {
        guard DiscordRpcManager.shared.isReady(), isEnabled else { return }
        let currentPosition = max(0, NowPlaying.shared.currentTime)
        let duration = NowPlaying.shared.duration > 0 ? NowPlaying.shared.duration : TimeInterval(song.duration)
        let clampedPosition = duration > 0 ? min(currentPosition, duration) : currentPosition
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs: Int64 = isPlaying ? nowMs - Int64(clampedPosition * 1000) : 0
        let remainingMs: Int64? = duration > 0 ? Int64(max(0, duration - clampedPosition) * 1000) : nil
        let endMs: Int64? = (isPlaying && remainingMs != nil) ? nowMs + max(0, remainingMs!) : nil

        let artistName = song.artists.map(\.name).joined(separator: ", ").nilIfEmpty ?? DiscordDefaults.unknownArtist
        let albumName = song.album
        let songTitle = song.title
        // Try to use thumbnailUrl as largeImage only; smallImage nil for now
        let advancedMode = UserDefaults.standard.bool(forKey: SettingsKeys.advancedMode)
        let activityType = Int(UserDefaults.standard.string(forKey: SettingsKeys.activityType) ?? DiscordDefaults.activityType) ?? 2
        let activityName = UserDefaults.standard.string(forKey: SettingsKeys.activityName) ?? ""
        let stateTemplate = UserDefaults.standard.string(forKey: SettingsKeys.stateTemplate) ?? DiscordDefaults.stateTemplate
        let detailsTemplate = UserDefaults.standard.string(forKey: SettingsKeys.detailsTemplate) ?? DiscordDefaults.detailsTemplate
        let btn1Enabled = UserDefaults.standard.object(forKey: SettingsKeys.button1Enabled) as? Bool ?? true
        let btn1Label = UserDefaults.standard.string(forKey: SettingsKeys.button1Label) ?? DiscordDefaults.button1Label
        let btn1Url = UserDefaults.standard.string(forKey: SettingsKeys.button1Url) ?? DiscordDefaults.button1UrlTemplate
        let btn2Enabled = UserDefaults.standard.object(forKey: SettingsKeys.button2Enabled) as? Bool ?? true
        let btn2Label = UserDefaults.standard.string(forKey: SettingsKeys.button2Label) ?? DiscordDefaults.button2Label
        let btn2Url = UserDefaults.standard.string(forKey: SettingsKeys.button2Url) ?? DiscordDefaults.button2Url

        // Resolve artist thumbnail from song? SongItem has no artist thumbnail; use nil
        let activity = DiscordActivityBuilder.build(
            song: song,
            artistName: artistName,
            albumName: albumName,
            artistThumbnail: nil,
            songTitle: songTitle,
            startTimestamp: startMs,
            endTimestamp: endMs,
            advancedMode: advancedMode,
            activityType: activityType,
            activityName: activityName,
            stateTemplate: stateTemplate,
            detailsTemplate: detailsTemplate,
            btn1Enabled: btn1Enabled,
            btn1Label: btn1Label,
            btn1Url: btn1Url,
            btn2Enabled: btn2Enabled,
            btn2Label: btn2Label,
            btn2Url: btn2Url
        )

        let statusStr = UserDefaults.standard.string(forKey: SettingsKeys.userStatus) ?? DiscordDefaults.userStatus
        let presenceStatus: PresenceStatus = {
            switch statusStr {
            case "idle": return advancedMode ? .idle : .online
            case "dnd": return advancedMode ? .dnd : .online
            default: return .online
            }
        }()

        DiscordRpcManager.shared.setActivity(activity: activity, songId: song.videoId, isPlaying: isPlaying, status: presenceStatus)
    }
}

private enum SettingsKeys {
    static let advancedMode = "discordAdvancedMode"
    static let activityType = "discordActivityType"
    static let activityName = "discordActivityName"
    static let stateTemplate = "discordStateTemplate"
    static let detailsTemplate = "discordDetailsTemplate"
    static let button1Enabled = "discordButton1Enabled"
    static let button1Label = "discordButton1Label"
    static let button1Url = "discordButton1Url"
    static let button2Enabled = "discordButton2Enabled"
    static let button2Label = "discordButton2Label"
    static let button2Url = "discordButton2Url"
    static let userStatus = "discordUserStatus"
}
private extension UserDefaults {
    @objc dynamic var discordRPCEnableValue: Bool {
        object(forKey: "discordRPCEnable") as? Bool ?? true
    }
}
