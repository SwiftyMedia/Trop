//
//  LyricsService.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import Foundation

/// Per-word timing for karaoke-style highlighting. Absent when only line sync is available.
struct LyricWord: Equatable, Sendable, Hashable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

struct LyricLine: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    let startTime: TimeInterval?
    /// Real word/syllable timings from the provider when available (richsync, yrc, enhanced LRC).
    let words: [LyricWord]?

    init(text: String, startTime: TimeInterval?, words: [LyricWord]? = nil) {
        self.text = text
        self.startTime = startTime
        self.words = words
    }

    var hasWordTimings: Bool {
        guard let words, words.count >= 2 else { return false }
        return true
    }

    static let placeholder = LyricLine(text: "♪", startTime: nil)
}

@MainActor
@Observable
final class LyricsState {
    static let shared = LyricsState()

    /// Songs with confirmed lyrics. Populated by preload/fetch.
    var availableVideoIds: Set<String> = []
    var providerName: String?
    var refreshToken: Int = 0

    private init() {}
}

actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: [LyricLine]] = [:]
    private var customs: [String: (lines: [LyricLine], providerName: String)] = [:]
    private var inFlight: [String: Task<FetchResult, Error>] = [:]

    private init() {}

    private static func customKey(_ videoId: String) -> String { "lyrics.custom.\(videoId)" }
    private static func customProviderKey(_ videoId: String) -> String { "lyrics.customProvider.\(videoId)" }

    private struct FetchResult: Sendable {
        let lines: [LyricLine]
        let providerName: String?
    }

    func fetchLyrics(videoId: String) async throws -> [LyricLine] {
        if let custom = customEntry(for: videoId) {
            await updateAvailability(videoId: videoId, available: true, providerName: custom.providerName)
            return custom.lines
        }
        if let cached = cache[videoId] {
            await updateAvailability(videoId: videoId, available: !cached.isEmpty)
            return cached
        }
        if let flight = inFlight[videoId] {
            return try await flight.value.lines
        }
        guard let query = await resolveQuery(videoId: videoId) else {
            await updateAvailability(videoId: videoId, available: false)
            throw LyricsError.notFound
        }
        let flight = Task<FetchResult, Error> {
            let (lines, providerName) = try await LyricsManager.shared.fetchLyricsReturningProvider(query: query)
            return FetchResult(lines: lines, providerName: providerName)
        }
        inFlight[videoId] = flight
        do {
            let result = try await flight.value
            inFlight.removeValue(forKey: videoId)
            // Only cache successful lookups — empty results should be retried later
            // since lyrics can be matched/published after playback starts.
            if !result.lines.isEmpty {
                cache[videoId] = result.lines
            }
            await updateAvailability(videoId: videoId, available: !result.lines.isEmpty, providerName: result.providerName)
            return result.lines
        } catch {
            inFlight.removeValue(forKey: videoId)
            if !(error is CancellationError) {
                await updateAvailability(videoId: videoId, available: false)
            }
            throw error
        }
    }

    // MARK: - Manual Manipulations (edit / refetch / search selection / copy)

    /// Raw text of the active lyrics for the editor.
    func editableText(videoId: String) -> String {
        if let custom = customEntry(for: videoId) {
            return LyricsParsing.serializeLines(custom.lines)
        }
        if let cached = cache[videoId] {
            return LyricsParsing.serializeLines(cached)
        }
        return ""
    }

    /// Plain text without timestamps for the clipboard.
    func plainTextForCopy(videoId: String) -> String? {
        if let custom = customEntry(for: videoId) {
            return LyricsParsing.plainText(custom.lines)
        }
        if let cached = cache[videoId] {
            return LyricsParsing.plainText(cached)
        }
        return nil
    }

    /// Stores edited or search-selected lyrics and signals the view to reload.
    func saveCustom(videoId: String, rawText: String, providerName: String?) {
        let lines = LyricsParsing.parseStoredText(rawText)
        guard !lines.isEmpty else { return }
        // Edits keep the existing provider; fresh selections pass their own.
        let provider = providerName
            ?? customs[videoId]?.providerName
            ?? UserDefaults.standard.string(forKey: Self.customProviderKey(videoId))
            ?? "Manual"
        customs[videoId] = (lines, provider)
        UserDefaults.standard.set(rawText, forKey: Self.customKey(videoId))
        UserDefaults.standard.set(provider, forKey: Self.customProviderKey(videoId))
        cache.removeValue(forKey: videoId)
        Task {
            await MainActor.run {
                LyricsState.shared.availableVideoIds.insert(videoId)
                LyricsState.shared.providerName = provider
                LyricsState.shared.refreshToken += 1
            }
        }
    }

    /// Re-fetches from providers; replaces any manual override with the fresh
    /// result (explicit user intent), like Metrolist's refetchLyrics.
    func refetch(videoId: String) async {
        cache.removeValue(forKey: videoId)
        func signalReload() {
            Task { await MainActor.run { LyricsState.shared.refreshToken += 1 } }
        }
        guard let query = await resolveQuery(videoId: videoId),
              let (fetchedLines, fetchedProvider) = try? await LyricsManager.shared.fetchLyricsReturningProvider(query: query),
              !fetchedLines.isEmpty else {
            await updateAvailability(videoId: videoId, available: false)
            signalReload()
            return
        }
        cache[videoId] = fetchedLines
        let raw = LyricsParsing.serializeLines(fetchedLines)
        let provider = fetchedProvider ?? "Manual"
        customs[videoId] = (fetchedLines, provider)
        UserDefaults.standard.set(raw, forKey: Self.customKey(videoId))
        UserDefaults.standard.set(provider, forKey: Self.customProviderKey(videoId))
        await updateAvailability(videoId: videoId, available: true, providerName: provider)
        signalReload()
    }

    private func customEntry(for videoId: String) -> (lines: [LyricLine], providerName: String)? {
        if let entry = customs[videoId] { return entry }
        guard let raw = UserDefaults.standard.string(forKey: Self.customKey(videoId)) else { return nil }
        let lines = LyricsParsing.parseStoredText(raw)
        guard !lines.isEmpty else { return nil }
        let provider = UserDefaults.standard.string(forKey: Self.customProviderKey(videoId)) ?? "Manual"
        let entry = (lines, provider)
        customs[videoId] = entry
        return entry
    }

    func preload(videoId: String, upcoming: [String] = []) async {
        _ = try? await fetchLyrics(videoId: videoId)
        for id in upcoming where cache[id] == nil && customEntry(for: id) == nil {
            _ = try? await fetchLyrics(videoId: id)
        }
    }

    private func updateAvailability(videoId: String, available: Bool, providerName: String? = nil) async {
        await MainActor.run {
            if available {
                LyricsState.shared.availableVideoIds.insert(videoId)
            } else {
                LyricsState.shared.availableVideoIds.remove(videoId)
            }
        }
        let currentId = await MainActor.run { NowPlaying.shared.videoId }
        guard currentId == videoId else { return }
        await MainActor.run {
            if available { LyricsState.shared.providerName = providerName }
        }
    }

    private func resolveQuery(videoId: String) async -> LyricsQuery? {
        let info = await MainActor.run {
            let np = NowPlaying.shared
            return (
                title: np.title,
                artist: np.displayArtist,
                album: np.albumTitle.isEmpty ? nil : np.albumTitle,
                duration: np.duration,
                currentId: np.videoId,
                queue: np.queueSongs
            )
        }

        let (npTitle, npArtist, npAlbum, npDuration, currentId, queue) = info

        let title: String
        let artist: String
        let album: String?
        let duration: TimeInterval

        if currentId == videoId, !npTitle.isEmpty, !npArtist.isEmpty {
            title = npTitle
            artist = npArtist
            album = npAlbum
            duration = npDuration
        } else if let song = queue.first(where: { $0.videoId == videoId }) {
            title = song.title
            artist = song.artists.map(\.name).joined(separator: ", ")
            album = song.album?.isEmpty == false ? song.album : nil
            let dur = song.duration > 0 ? song.duration : (DurationCache.get(videoId) ?? 0)
            duration = TimeInterval(dur)
        } else {
            return nil
        }

        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let cleaned = cleanQuery(title: title, artist: artist, album: album)
        return LyricsQuery(
            title: cleaned.title,
            artist: cleaned.artist,
            album: cleaned.album,
            duration: duration > 0 ? duration : 0
        )
    }

    private struct CleanedQuery {
        let title: String
        let artist: String
        let album: String?
    }

    private func cleanQuery(title: String, artist: String, album: String?) -> CleanedQuery {
        let (extractedTitle, extractedArtist) = Self.extractArtistTitle(from: title, channelArtist: artist)
        let cleanedTitle = Self.cleanTitle(extractedTitle)
        let cleanedArtist = Self.cleanArtist(extractedArtist ?? artist)
        let cleanedAlbum = album.map { Self.cleanAlbum($0) }
        return CleanedQuery(title: cleanedTitle, artist: cleanedArtist, album: cleanedAlbum)
    }

    private static func extractArtistTitle(from rawTitle: String, channelArtist: String) -> (title: String, artist: String?) {
        guard isChannelLike(channelArtist) else { return (rawTitle, nil) }
        let separators = [" - ", " – ", " — "]
        for sep in separators {
            if let range = rawTitle.range(of: sep) {
                let left = String(rawTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(rawTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !left.isEmpty, !right.isEmpty else { break }
                // left = real artist, right = real title
                return (right, left)
            }
        }
        return (rawTitle, nil)
    }

    private static func isChannelLike(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !lower.isEmpty else { return false }
        let channelWords = ["music", "channel", "official", "records", "record",
                           "tv", "studio", "entertainment", "4k", "中文", "古风",
                           "chinese", "ort", "ehp", "vip", "lyrics", "mv",
                           "topic", "vevo", "remix", "dj", "radio"]
        return channelWords.contains(where: { lower.contains($0) })
    }

    private static func cleanTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"「[^」]*」"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"『[^』]*』"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        for marker in ["|", "♪", "mv", "lyrics", "歌词", "動態", "动态", "official", "官方"] {
            if let r = s.range(of: marker, options: .caseInsensitive) {
                s = String(s[..<r.lowerBound])
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanArtist(_ raw: String) -> String {
        let parts = raw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { part -> String in
                var p = part
                if let range = p.range(of: " - ") {
                    p = String(p[..<range.lowerBound])
                }
                p = p.replacingOccurrences(of: " - Topic", with: "")
                p = p.replacingOccurrences(of: "-Topic", with: "")
                p = p.replacingOccurrences(of: "Topic", with: "")
                return p.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    private static func cleanAlbum(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
