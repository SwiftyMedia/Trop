//
//  LyricsManager.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import Foundation

@Observable
@MainActor
final class LyricsSettings {
    static let shared = LyricsSettings()

    private let orderKey = "lyricsProviderOrder"

    /// Ordered provider ids. Defaults to a sensible fallback chain.
    var providerOrder: [String] = LyricsProviderRegistry.defaultOrder

    private init() {
        if let data = UserDefaults.standard.data(forKey: orderKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data),
           !decoded.isEmpty {
            // Drop ids that no longer have a provider (e.g. removed sources).
            let known = decoded.filter { LyricsProviderRegistry.provider(for: $0) != nil }
            providerOrder = known + LyricsProviderRegistry.defaultOrder.filter { !known.contains($0) }
        }
    }

    func saveProviderOrder(_ order: [String]) {
        providerOrder = order
        let data = (try? JSONEncoder().encode(order)) ?? Data()
        UserDefaults.standard.set(data, forKey: orderKey)
    }
}

/// Registry of all available providers.
enum LyricsProviderRegistry {
    static let all: [LyricsProvider] = [
        LRCLIBProvider(),
        LRCredProvider(),
        BetterLyricsProvider(),
        PaxsenixProvider(),
        UnisonProvider(),
        SimpMusicProvider(),
        MusixmatchProvider(),
        NeteaseProvider(),
        KugouProvider(),
        GeniusProvider()
    ]

    static let defaultOrder: [String] = [
        "lrclib",
        "lrc.red",
        "betterlyrics",
        "paxsenix",
        "unison",
        "simpmusic",
        "musixmatch",
        "netease",
        "kugou",
        "genius"
    ]

    static func provider(for id: String) -> LyricsProvider? {
        all.first { $0.id == id }
    }
}

actor LyricsManager {
    static let shared = LyricsManager()

    private init() {}

    struct LyricSearchResult: Identifiable {
        let id = UUID()
        let lines: [LyricLine]
        let providerName: String
        let sortOrder: Int

        var previewText: String {
            lines.prefix(2).map(\.text).joined(separator: "\n")
        }

        var isSynced: Bool {
            lines.contains { $0.startTime != nil }
        }
    }

    func fetchLyrics(query: LyricsQuery) async throws -> [LyricLine] {
        let (lines, _) = try await fetchLyricsReturningProvider(query: query)
        return lines
    }

    /// Queries every enabled provider concurrently and returns all matches.
    func searchAll(query: LyricsQuery) async -> [LyricSearchResult] {
        let order = await LyricsSettings.shared.providerOrder
        let disabled = SettingsStore.shared.disabledLyricsProviders
        let providers = order
            .compactMap { LyricsProviderRegistry.provider(for: $0) }
            .filter { !disabled.contains($0.id) }
            .enumerated().map { ($1, $0) }

        return await withTaskGroup(of: (Int, LyricSearchResult)?.self) { group in
            for (provider, index) in providers {
                group.addTask {
                    guard let lines = try? await provider.fetch(query: query), !lines.isEmpty else { return nil }
                    return (index, LyricSearchResult(lines: lines, providerName: provider.name, sortOrder: index))
                }
            }
            var results: [(Int, LyricSearchResult)] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func fetchLyricsReturningProvider(query: LyricsQuery) async throws -> ([LyricLine], providerName: String?) {
        let order = await LyricsSettings.shared.providerOrder
        let disabled = SettingsStore.shared.disabledLyricsProviders
        let candidates: [(index: Int, provider: LyricsProvider)] = order.enumerated().compactMap { index, id in
            guard !disabled.contains(id), let provider = LyricsProviderRegistry.provider(for: id) else { return nil }
            return (index, provider)
        }
        guard !candidates.isEmpty else { throw LyricsError.notFound }

        // Metrolist uses the configured provider order as a real fallback
        // chain. Concurrent requests made a slow, weak match win over a
        // better provider because Trop selected only by array position after
        // all responses arrived.
        var unsyncedFallback: (lines: [LyricLine], providerName: String)?
        for (_, provider) in candidates {
            do {
                let lines = try await Self.withTimeout(seconds: 10) {
                    try await provider.fetch(query: query)
                }
                guard !lines.isEmpty else {
                    logFetchFailure(provider: provider, query: query, received: "empty lyrics result")
                    continue
                }

                // Synced lyrics drive auto-scroll, line highlighting and
                // tap-to-seek. Keep an unsynced result as a last resort, but
                // keep looking for a provider that can follow playback.
                guard lines.contains(where: { $0.startTime != nil }) else {
                    if unsyncedFallback == nil {
                        unsyncedFallback = (lines, provider.name)
                    }
                    continue
                }

                return (lines, provider.name)
            } catch {
                if !(error is CancellationError) {
                    logFetchFailure(provider: provider, query: query, received: error.localizedDescription)
                }
                continue
            }
        }

        if let unsyncedFallback {
            return (unsyncedFallback.lines, unsyncedFallback.providerName)
        }
        throw LyricsError.notFound
    }

    private func logFetchFailure(provider: LyricsProvider, query: LyricsQuery, received: String) {
        let songLink: String
        if let videoId = query.videoId {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.youtube.com"
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: videoId)]
            songLink = components.url?.absoluteString ?? "unavailable"
        } else {
            songLink = "unavailable"
        }

        Log.lyrics.error(
            "Lyrics fetch failed provider=\(provider.name) song=\"\(query.title)\" "
                + "artist=\"\(query.artist)\" link=\(songLink) received=\"\(received)\""
        )
    }

    private static func withTimeout<T: Sendable>(seconds: Double, work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LyricsError.notFound
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw LyricsError.notFound
            }
            group.cancelAll()
            return first
        }
    }
}
