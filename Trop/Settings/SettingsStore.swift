//
//  SettingsStore.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

protocol SettingsOption: CaseIterable, Hashable, Identifiable, RawRepresentable where RawValue == String {
    var displayName: String { get }
}

enum ThemeMode: String, CaseIterable, Identifiable, SettingsOption {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum PlayerBackgroundStyle: String, CaseIterable, Identifiable, SettingsOption {
    case dynamic
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dynamic: return "Album Art"
        case .solid: return "Solid"
        }
    }
}

enum LyricsAlignment: String, CaseIterable, Identifiable, SettingsOption {
    case left
    case center
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    var iconName: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    var textAlignment: Alignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var multilineTextAlignment: TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

extension AudioQuality: SettingsOption {
    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

extension DownloadQuality: SettingsOption {
    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .high: return "High (128–192 kbps)"
        case .standard: return "Standard (64–96 kbps)"
        }
    }
}

struct AccentPreset: Identifiable, Hashable {
    let name: String
    let color: Color

    var id: String { name }

    /// The pre-baked alternate app icon matching this accent, or nil when
    /// the accent equals the default.
    var alternateIconName: String? {
        nil
    }

    static let all: [AccentPreset] = [
        AccentPreset(name: "Red", color: Color(red: 0.91, green: 0.22, blue: 0.22)),
        AccentPreset(name: "Blue", color: Color(red: 0, green: 0.48, blue: 1)),
        AccentPreset(name: "Orange", color: Color(red: 0.95, green: 0.45, blue: 0.13)),
        AccentPreset(name: "Amber", color: Color(red: 0.98, green: 0.70, blue: 0.15)),
        AccentPreset(name: "Green", color: Color(red: 0.18, green: 0.72, blue: 0.32)),
        AccentPreset(name: "Teal", color: Color(red: 0.12, green: 0.65, blue: 0.60)),
        AccentPreset(name: "Cyan", color: Color(red: 0.15, green: 0.70, blue: 0.90)),
        AccentPreset(name: "Purple", color: Color(red: 0.60, green: 0.35, blue: 0.90)),
        AccentPreset(name: "Pink", color: Color(red: 0.94, green: 0.35, blue: 0.66)),
        AccentPreset(name: "Indigo", color: Color(red: 0.33, green: 0.40, blue: 0.95)),
        AccentPreset(name: "Lime", color: Color(red: 0.55, green: 0.75, blue: 0.20)),
        AccentPreset(name: "Brown", color: Color(red: 0.62, green: 0.43, blue: 0.30))
    ]
}

@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    // MARK: - Appearance

    var themeMode: ThemeMode {
        didSet { Self.defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    var accentColor: Color = AccentPreset.all[0].color

    var accentName: String {
        didSet {
            Self.defaults.set(accentName, forKey: Keys.accentName)
            accentColor = AccentPreset.all.first { $0.name == accentName }?.color ?? AccentPreset.all[0].color
        }
    }

    var playerBackgroundStyle: PlayerBackgroundStyle {
        didSet { Self.defaults.set(playerBackgroundStyle.rawValue, forKey: Keys.playerBackgroundStyle) }
    }

    var preferredColorScheme: ColorScheme? {
        switch themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var defaultTab: Int {
        didSet { Self.defaults.set(defaultTab, forKey: Keys.defaultTab) }
    }

    // MARK: - Lyrics appearance

    var lyricsFontSize: Double {
        didSet { Self.defaults.set(lyricsFontSize, forKey: Keys.lyricsFontSize) }
    }

    var lyricsAlignment: LyricsAlignment {
        didSet { Self.defaults.set(lyricsAlignment.rawValue, forKey: Keys.lyricsAlignment) }
    }

    /// Shifts lyric timing by this many seconds (positive = later, negative = earlier).
    var lyricsOffsetSeconds: Double {
        didSet { Self.defaults.set(lyricsOffsetSeconds, forKey: Keys.lyricsOffsetSeconds) }
    }

    /// Shows a progress ring during long instrumental gaps in synced lyrics.
    var showIntervalIndicator: Bool {
        didSet { Self.defaults.set(showIntervalIndicator, forKey: Keys.showIntervalIndicator) }
    }

    /// Displays romanized lyrics for Japanese/Korean/Cyrillic lines when available.
    var romanizeCurrentTrack: Bool {
        didSet { Self.defaults.set(romanizeCurrentTrack, forKey: Keys.romanizeCurrentTrack) }
    }

    // MARK: - Playback

    var equalizerEnabled: Bool {
        didSet { Self.defaults.set(equalizerEnabled, forKey: Keys.equalizerEnabled) }
    }

    /// The id of the selected preset, or "custom" when the user edited bands manually.
    var equalizerPresetID: String {
        didSet { Self.defaults.set(equalizerPresetID, forKey: Keys.equalizerPresetID) }
    }

    /// Current band gains in dB, one per `equalizerFrequencies`.
    var equalizerGains: [Double] {
        didSet { Self.defaults.set(equalizerGains, forKey: Keys.equalizerGains) }
    }

    var audioQuality: AudioQuality {
        didSet { Self.defaults.set(audioQuality.rawValue, forKey: Keys.audioQuality) }
    }

    var audioNormalization: Bool {
        didSet { Self.defaults.set(audioNormalization, forKey: Keys.audioNormalization) }
    }

    var gaplessPlayback: Bool {
        didSet { Self.defaults.set(gaplessPlayback, forKey: Keys.gaplessPlayback) }
    }

    var autoplaySimilar: Bool {
        didSet { Self.defaults.set(autoplaySimilar, forKey: Keys.autoplaySimilar) }
    }

    var persistQueue: Bool {
        didSet { Self.defaults.set(persistQueue, forKey: Keys.persistQueue) }
    }

    var lastRadioStyle: RadioStyle {
        didSet { Self.defaults.set(lastRadioStyle.rawValue, forKey: Keys.lastRadioStyle) }
    }

    var lastRadioLimit: Int {
        didSet { Self.defaults.set(lastRadioLimit, forKey: Keys.lastRadioLimit) }
    }

    var lastRadioAllowExplicit: Bool {
        didSet { Self.defaults.set(lastRadioAllowExplicit, forKey: Keys.lastRadioAllowExplicit) }
    }

    var playerVolume: Double {
        didSet { Self.defaults.set(playerVolume, forKey: Keys.playerVolume) }
    }

    var artworkSwipeNavigation: Bool {
        didSet { Self.defaults.set(artworkSwipeNavigation, forKey: Keys.artworkSwipeNavigation) }
    }

    // MARK: - Content

    var hideExplicit: Bool {
        didSet { Self.defaults.set(hideExplicit, forKey: Keys.hideExplicit) }
    }

    var showQuickPicks: Bool {
        didSet { Self.defaults.set(showQuickPicks, forKey: Keys.showQuickPicks) }
    }

    var topListsLength: Int {
        didSet { Self.defaults.set(topListsLength, forKey: Keys.topListsLength) }
    }

    var contentCountry: String {
        didSet {
            Self.defaults.set(contentCountry, forKey: Keys.contentCountry)
            Task { await InnerTubeClient.tropShared.syncTropLocale() }
        }
    }

    // MARK: - Lyrics providers

    var disabledLyricsProviders: Set<String> {
        didSet { Self.defaults.set(disabledLyricsProviders.sorted(), forKey: Keys.disabledLyricsProviders) }
    }

    // MARK: - Privacy

    var trackSearchHistory: Bool {
        didSet { Self.defaults.set(trackSearchHistory, forKey: Keys.trackSearchHistory) }
    }

    var trackPlayHistory: Bool {
        didSet { Self.defaults.set(trackPlayHistory, forKey: Keys.trackPlayHistory) }
    }

    // MARK: - Downloads & storage

    var downloadQuality: DownloadQuality {
        didSet { Self.defaults.set(downloadQuality.rawValue, forKey: Keys.downloadQuality) }
    }

    var wifiOnlyDownloads: Bool {
        didSet { Self.defaults.set(wifiOnlyDownloads, forKey: Keys.wifiOnlyDownloads) }
    }

    var autoDownloadOnLike: Bool {
        didSet { Self.defaults.set(autoDownloadOnLike, forKey: Keys.autoDownloadOnLike) }
    }

    var autoDownloadNewEpisodes: Bool {
        didSet { Self.defaults.set(autoDownloadNewEpisodes, forKey: Keys.autoDownloadNewEpisodes) }
    }

    // MARK: - Sync

    var syncArtists: Bool {
        didSet { Self.defaults.set(syncArtists, forKey: Keys.syncArtists) }
    }

    var syncPlaylists: Bool {
        didSet { Self.defaults.set(syncPlaylists, forKey: Keys.syncPlaylists) }
    }

    var syncAlbums: Bool {
        didSet { Self.defaults.set(syncAlbums, forKey: Keys.syncAlbums) }
    }

    var syncPodcasts: Bool {
        didSet { Self.defaults.set(syncPodcasts, forKey: Keys.syncPodcasts) }
    }

    var syncSongs: Bool {
        didSet { Self.defaults.set(syncSongs, forKey: Keys.syncSongs) }
    }

    // MARK: - Spotify Canvas

    var canvasEnabled: Bool {
        didSet { Self.defaults.set(canvasEnabled, forKey: Keys.canvasEnabled) }
    }

    var canvasOverCellular: Bool {
        didSet { Self.defaults.set(canvasOverCellular, forKey: Keys.canvasOverCellular) }
    }

    // MARK: - Keys

    private enum Keys {
        static let themeMode = "settings.themeMode"
        static let accentName = "settings.accentName"
        static let playerBackgroundStyle = "settings.playerBackgroundStyle"
        static let defaultTab = "settings.defaultTab"
        static let lyricsFontSize = "settings.lyricsFontSize"
        static let lyricsAlignment = "settings.lyricsAlignment"
        static let lyricsOffsetSeconds = "settings.lyricsOffsetSeconds"
        static let showIntervalIndicator = "settings.showIntervalIndicator"
        static let romanizeCurrentTrack = "settings.romanizeCurrentTrack"
        static let equalizerEnabled = "settings.equalizerEnabled"
        static let equalizerPresetID = "settings.equalizerPresetID"
        static let equalizerGains = "settings.equalizerGains"
        static let audioQuality = "settings.audioQuality"
        static let audioNormalization = "settings.audioNormalization"
        static let gaplessPlayback = "settings.gaplessPlayback"
        static let autoplaySimilar = "settings.autoplaySimilar"
        static let persistQueue = "settings.persistQueue"
        static let lastRadioStyle = "settings.lastRadioStyle"
        static let lastRadioLimit = "settings.lastRadioLimit"
        static let lastRadioAllowExplicit = "settings.lastRadioAllowExplicit"
        static let playerVolume = "settings.playerVolume"
        static let artworkSwipeNavigation = "settings.artworkSwipeNavigation"
        static let hideExplicit = "settings.hideExplicit"
        static let showQuickPicks = "settings.showQuickPicks"
        static let topListsLength = "settings.topListsLength"
        static let contentCountry = "settings.contentCountry"
        static let disabledLyricsProviders = "settings.disabledLyricsProviders"
        static let trackSearchHistory = "settings.trackSearchHistory"
        static let trackPlayHistory = "settings.trackPlayHistory"
        static let downloadQuality = "settings.downloadQuality"
        static let wifiOnlyDownloads = "settings.wifiOnlyDownloads"
        static let autoDownloadOnLike = "settings.autoDownloadOnLike"
        static let autoDownloadNewEpisodes = "settings.autoDownloadNewEpisodes"
        static let syncArtists = "settings.syncArtists"
        static let syncPlaylists = "settings.syncPlaylists"
        static let syncAlbums = "settings.syncAlbums"
        static let syncPodcasts = "settings.syncPodcasts"
        static let syncSongs = "settings.syncSongs"
        static let canvasEnabled = "settings.canvasEnabled"
        static let canvasOverCellular = "settings.canvasOverCellular"
    }

    private static let defaults: UserDefaults = .standard

    private static func load<T>(_ key: String, default defaultValue: T) -> T {
        defaults.object(forKey: key) as? T ?? defaultValue
    }

    private static func loadString(_ key: String, default defaultValue: String) -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    private static func loadEnum<E: RawRepresentable>(_ key: String, default defaultValue: E) -> E where E.RawValue == String {
        E(rawValue: defaults.string(forKey: key) ?? "") ?? defaultValue
    }

    private init() {
        let d = Self.defaults
        themeMode = Self.loadEnum(Keys.themeMode, default: .system)
        accentColor = AccentPreset.all
            .first { $0.name == (d.string(forKey: Keys.accentName) ?? AccentPreset.all[0].name) }?
            .color ?? AccentPreset.all[0].color
        accentName = d.string(forKey: Keys.accentName) ?? AccentPreset.all[0].name
        playerBackgroundStyle = Self.loadEnum(Keys.playerBackgroundStyle, default: .dynamic)
        // Migrated when Explore took index 2 (was Search): stored 2 → 3.
        let storedTab = Self.load(Keys.defaultTab, default: 0)
        defaultTab = storedTab == 2 ? 3 : storedTab
        lyricsFontSize = Self.load(Keys.lyricsFontSize, default: 17)
        lyricsAlignment = Self.loadEnum(Keys.lyricsAlignment, default: .center)
        lyricsOffsetSeconds = Self.load(Keys.lyricsOffsetSeconds, default: 0)
        showIntervalIndicator = Self.load(Keys.showIntervalIndicator, default: true)
        romanizeCurrentTrack = Self.load(Keys.romanizeCurrentTrack, default: true)
        equalizerEnabled = Self.load(Keys.equalizerEnabled, default: false)
        equalizerPresetID = Self.loadString(Keys.equalizerPresetID, default: "flat")
        if let saved = d.array(forKey: Keys.equalizerGains) as? [Double], saved.count == equalizerFrequencies.count {
            equalizerGains = saved
        } else {
            equalizerGains = EqualizerPresets.all.first?.gains ?? Array(repeating: 0, count: equalizerFrequencies.count)
        }
        audioQuality = Self.loadEnum(Keys.audioQuality, default: .auto)
        audioNormalization = Self.load(Keys.audioNormalization, default: false)
        gaplessPlayback = Self.load(Keys.gaplessPlayback, default: true)
        autoplaySimilar = Self.load(Keys.autoplaySimilar, default: true)
        persistQueue = Self.load(Keys.persistQueue, default: false)
        lastRadioStyle = Self.loadEnum(Keys.lastRadioStyle, default: .similar)
        lastRadioLimit = Self.load(Keys.lastRadioLimit, default: 25)
        lastRadioAllowExplicit = Self.load(Keys.lastRadioAllowExplicit, default: true)
        playerVolume = Self.load(Keys.playerVolume, default: 1)
        artworkSwipeNavigation = Self.load(Keys.artworkSwipeNavigation, default: true)
        hideExplicit = Self.load(Keys.hideExplicit, default: false)
        showQuickPicks = Self.load(Keys.showQuickPicks, default: true)
        topListsLength = Self.load(Keys.topListsLength, default: 8)
        contentCountry = Self.loadString(Keys.contentCountry, default: "US")
        disabledLyricsProviders = Set(d.stringArray(forKey: Keys.disabledLyricsProviders) ?? [])
        trackSearchHistory = Self.load(Keys.trackSearchHistory, default: true)
        trackPlayHistory = Self.load(Keys.trackPlayHistory, default: true)
        downloadQuality = Self.loadEnum(Keys.downloadQuality, default: .auto)
        wifiOnlyDownloads = Self.load(Keys.wifiOnlyDownloads, default: false)
        autoDownloadOnLike = Self.load(Keys.autoDownloadOnLike, default: false)
        autoDownloadNewEpisodes = Self.load(Keys.autoDownloadNewEpisodes, default: false)
        syncArtists = Self.load(Keys.syncArtists, default: true)
        syncPlaylists = Self.load(Keys.syncPlaylists, default: true)
        syncAlbums = Self.load(Keys.syncAlbums, default: true)
        syncPodcasts = Self.load(Keys.syncPodcasts, default: true)
        syncSongs = Self.load(Keys.syncSongs, default: true)
        canvasEnabled = Self.load(Keys.canvasEnabled, default: false)
        canvasOverCellular = Self.load(Keys.canvasOverCellular, default: false)
    }
}

// MARK: - Environment Key

private struct SettingsStoreKey: EnvironmentKey {
    static let defaultValue: SettingsStore = .shared
}

extension EnvironmentValues {
    var settingsStore: SettingsStore {
        get { self[SettingsStoreKey.self] }
        set { self[SettingsStoreKey.self] = newValue }
    }
}
