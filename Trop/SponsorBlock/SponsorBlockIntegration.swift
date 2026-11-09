//
//  SponsorBlock.swift
//  Trop
//
//  Created by 686udjie on 23/07/2026.
//

import CryptoKit
import Foundation

enum SponsorBlock {
    private static let enabledKey = "sponsorBlockEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func save(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}

@MainActor
final class SponsorBlockIntegration {
    static let shared = SponsorBlockIntegration()

    private struct Segment: Sendable {
        let start: Double
        let end: Double
    }

    private var videoId: String?
    private var segments: [Segment] = []
    private var skipped: Set<Int> = []
    private var prefetchedSegments: [String: [Segment]] = [:]
    private var fetchTasks: [String: Task<[Segment], Never>] = [:]

    private init() {}

    func warm(for videoId: String?) {
        guard SponsorBlock.isEnabled, let videoId else { return }
        _ = fetchTask(for: videoId)
    }

    func preloadedStartOffset(for videoId: String?) async -> Double {
        guard SponsorBlock.isEnabled, let videoId else { return 0 }
        let found: [Segment]
        if let cached = prefetchedSegments[videoId] {
            found = cached
        } else if let task = fetchTasks[videoId] {
            found = await task.value
        } else {
            return 0
        }
        guard SponsorBlock.isEnabled,
              let first = found.first,
              first.start < 0.5
        else { return 0 }
        return first.end
    }

    /// Called by NowPlaying's timer after it updates the position.
    func tick() {
        let nowPlaying = NowPlaying.shared
        guard SponsorBlock.isEnabled, let id = nowPlaying.videoId else { return }
        if id != videoId {
            videoId = id
            segments = []
            skipped = []
            if let found = prefetchedSegments[id] {
                segments = found
            } else {
                _ = fetchTask(for: id)
            }
            return
        }
        guard nowPlaying.isPlaying else { return }
        let player = PlayerController.shared
        guard player.currentVideoId == id, player.pendingVideoId == nil else { return }
        let position = nowPlaying.currentTime
        for (index, segment) in segments.enumerated() where !skipped.contains(index) {
            // Within the last second the jump isn't worth it.
            guard position >= segment.start, position < segment.end - 1 else { continue }
            skipped.insert(index)
            player.seek(to: segment.end, isUserAction: false)
            return
        }
    }

    private func fetchTask(for videoId: String) -> Task<[Segment], Never> {
        if let task = fetchTasks[videoId] {
            return task
        }
        if let cached = prefetchedSegments[videoId] {
            return Task { cached }
        }

        let task = Task { await Self.fetchSegments(videoId: videoId) }
        fetchTasks[videoId] = task
        Task { [weak self] in
            let found = await task.value
            guard let self else { return }
            self.fetchTasks.removeValue(forKey: videoId)
            self.prefetchedSegments[videoId] = found
            if self.prefetchedSegments.count > 64 {
                self.prefetchedSegments.removeAll(keepingCapacity: true)
            }
            if self.videoId == videoId {
                self.segments = found
            }
        }
        return task
    }

    private struct VideoSegments: Decodable {
        struct Raw: Decodable {
            let category: String
            let actionType: String?
            let segment: [Double]
        }

        let videoID: String
        let segments: [Raw]
    }

    /// Returns non-music segments for a video, or an empty list when they
    /// aren't available.
    private nonisolated static func fetchSegments(videoId: String) async -> [Segment] {
        let hash = SHA256.hash(data: Data(videoId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")
        components?.queryItems = [URLQueryItem(name: "categories", value: "[\"music_offtopic\"]")]
        guard let url = components?.url else {
            Log.sponsorBlock.error("Could not build SponsorBlock URL videoId=\(videoId)")
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Log.sponsorBlock.error("Invalid SponsorBlock response videoId=\(videoId)")
                return []
            }
            guard http.statusCode == 200 else {
                Log.sponsorBlock.error("SponsorBlock HTTP \(http.statusCode) videoId=\(videoId)")
                return []
            }
            let videos = try JSONDecoder().decode([VideoSegments].self, from: data)
            guard let video = videos.first(where: { $0.videoID == videoId }) else { return [] }
            return video.segments
            .filter {
                $0.category == "music_offtopic"
                    && ($0.actionType ?? "skip") == "skip"
                    && $0.segment.count == 2
                    && $0.segment[1] > $0.segment[0]
            }
            .map { Segment(start: $0.segment[0], end: $0.segment[1]) }
            .sorted { $0.start < $1.start }
        } catch {
            Log.sponsorBlock.error("SponsorBlock fetch failed videoId=\(videoId): \(error.localizedDescription)")
            return []
        }
    }
}
