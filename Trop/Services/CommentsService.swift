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
    case rejected(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return NSLocalizedString("Comments are disabled for this song", comment: "")
        case .empty:
            return NSLocalizedString("No comments yet", comment: "")
        case .rejected(let message):
            return message
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

    func performCommentAction(action: String) async throws -> Bool {
        do {
            await syncAuth(into: musicClient)
            let json = try await musicClient.performCommentAction(action: action, client: .web)
            return Self.voteSucceeded(json)
        } catch {
            await syncAuth(into: youtubeClient)
            do {
                let json = try await youtubeClient.performCommentAction(action: action, client: .web)
                return Self.voteSucceeded(json)
            } catch {
                throw CommentsError.underlying(error)
            }
        }
    }

    /// Posts a top-level comment with the server-issued params from the
    /// comments header. HTTP errors fall back from the music host to www;
    /// a 200 carrying `showErrorAction` is a real rejection, not retried.
    func postComment(params: String, text: String) async throws {
        let json: [String: Any]
        do {
            await syncAuth(into: musicClient)
            json = try await musicClient.createComment(params: params, text: text, client: .web)
        } catch {
            await syncAuth(into: youtubeClient)
            do {
                json = try await youtubeClient.createComment(params: params, text: text, client: .web)
            } catch {
                throw CommentsError.underlying(error)
            }
        }
        if let message = Self.postFailureMessage(json) {
            throw CommentsError.rejected(message)
        }
    }

    func updateComment(params: String, text: String) async throws {
        let json: [String: Any]
        do {
            await syncAuth(into: musicClient)
            json = try await musicClient.updateComment(params: params, text: text, client: .web)
        } catch {
            await syncAuth(into: youtubeClient)
            do {
                json = try await youtubeClient.updateComment(params: params, text: text, client: .web)
            } catch {
                throw CommentsError.underlying(error)
            }
        }
        if let message = Self.postFailureMessage(json) {
            throw CommentsError.rejected(message)
        }
    }

    private static func postFailureMessage(_ json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        guard let actions = json["actions"] as? [[String: Any]],
              let first = actions.first,
              let showError = first["showErrorAction"] as? [String: Any],
              let errorMessage = showError["errorMessage"] as? [String: Any],
              let renderer = errorMessage["messageRenderer"] as? [String: Any],
              let text = renderer["text"] as? [String: Any] else { return nil }
        if let simple = text["simpleText"] as? String { return simple }
        if let runs = text["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    private static func voteSucceeded(_ json: [String: Any]) -> Bool {
        let results = json["actionResults"] as? [[String: Any]]
        return results?.first?["status"] as? String == "STATUS_SUCCEEDED"
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

    /// Diagnostic: writes the raw comments page to Documents (overwritten
    /// on every fetch) so payload/menu shapes can be inspected off-device.
    private static func dumpCommentsPage(_ json: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: docs.appendingPathComponent("comments-own-debug.json"), options: .atomic)
    }

    private func fetchContinuationJSON(_ continuation: String) async throws -> [String: Any] {
        // Continuations are host-agnostic enough that music-first still works.
        let json: [String: Any]
        do {
            await syncAuth(into: musicClient)
            json = try await musicClient.next(continuation: continuation, client: .web)
        } catch {
            await syncAuth(into: youtubeClient)
            do {
                json = try await youtubeClient.next(continuation: continuation, client: .web)
            } catch {
                throw CommentsError.underlying(error)
            }
        }
        Self.dumpCommentsPage(json)
        return json
    }

    private func syncAuth(into client: InnerTubeClient) async {
        let store = CookieStore()
        await client.loadState(from: store)
        await client.syncTropLocale()
    }
}
