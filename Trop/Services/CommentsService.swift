//
//  CommentsService.swift
//  Trop
//
//  Created by 686udjie on 05/11/2026.
//

import Foundation

enum CommentsError: LocalizedError {
    case disabled
    case empty
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return NSLocalizedString("Comments are disabled for this song", comment: "")
        case .empty:
            return NSLocalizedString("No comments yet", comment: "")
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

/// Fetches YouTube comment threads via InnerTube `/next` using the WEB client.
/// YT Music's WEB_REMIX client does not return the comments section.
actor CommentsService {
    static let shared = CommentsService()

    private let musicClient = InnerTubeClient.tropShared
    private let youtubeClient = InnerTubeClient(config: .youtube)

    func loadInitial(videoId: String) async throws -> CommentsPage {
        let token = try await initialCommentsToken(videoId: videoId)
        let page = try await fetchPage(continuation: token)
        if page.items.isEmpty, page.nextPageToken == nil {
            throw CommentsError.disabled
        }
        return page
    }

    func loadPage(continuation: String) async throws -> CommentsPage {
        try await fetchPage(continuation: continuation)
    }

    func loadReplies(continuation: String) async throws -> CommentRepliesPage {
        let json = try await fetchContinuationJSON(continuation)
        return CommentsParser.parseRepliesPage(json)
    }

    // MARK: - Private

    private func initialCommentsToken(videoId: String) async throws -> String {
        // Prefer the music host (same-origin for YTM session), then fall back to www.
        if let token = await commentsToken(videoId: videoId, client: musicClient) {
            return token
        }
        if let token = await commentsToken(videoId: videoId, client: youtubeClient) {
            return token
        }
        throw CommentsError.disabled
    }

    private func commentsToken(videoId: String, client: InnerTubeClient) async -> String? {
        do {
            await syncAuth(into: client)
            let json = try await client.next(videoId: videoId, client: .web)
            return CommentsParser.findInitialCommentsToken(in: json)
        } catch {
            return nil
        }
    }

    private func fetchPage(continuation: String) async throws -> CommentsPage {
        let json = try await fetchContinuationJSON(continuation)
        return CommentsParser.parseCommentsPage(json)
    }

    private func fetchContinuationJSON(_ continuation: String) async throws -> [String: Any] {
        // Continuations are host-agnostic enough that music-first still works.
        do {
            await syncAuth(into: musicClient)
            return try await musicClient.next(continuation: continuation, client: .web)
        } catch {
            await syncAuth(into: youtubeClient)
            do {
                return try await youtubeClient.next(continuation: continuation, client: .web)
            } catch {
                throw CommentsError.underlying(error)
            }
        }
    }

    private func syncAuth(into client: InnerTubeClient) async {
        let store = CookieStore()
        await client.loadState(from: store)
        await client.syncTropLocale()
    }
}
