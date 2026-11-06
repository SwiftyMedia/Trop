//
//  CommentModels.swift
//  Trop
//
//  Created by 686udjie on 05/11/2026.
//

import Foundation

enum CommentSort: String, CaseIterable, Identifiable, Sendable {
    case top
    case newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top"
        case .newest: return "Newest"
        }
    }
}

enum CommentTextRun: Hashable, Sendable {
    case text(String)
    case link(text: String, url: URL)
    case timestamp(text: String, seconds: Double, videoId: String?)
}

struct CommentAuthor: Hashable, Sendable {
    var name: String
    var avatarURL: String?
    var channelURL: String?
    var isCreator: Bool
    var isVerified: Bool
    var isArtist: Bool
}

struct CommentItem: Identifiable, Hashable, Sendable {
    var id: String
    var author: CommentAuthor
    var runs: [CommentTextRun]
    var publishedTime: String
    var likeCountText: String
    var isHearted: Bool
    var isPinned: Bool
    var pinnedText: String?
    var replyCount: Int
    var replyCountText: String
    var replyContinuation: String?
}

struct CommentsPage: Sendable {
    var items: [CommentItem]
    var nextPageToken: String?
    var sortTokens: [CommentSort: String]
    var totalCountText: String?
}

struct CommentRepliesPage: Sendable {
    var items: [CommentItem]
    var nextPageToken: String?
}
