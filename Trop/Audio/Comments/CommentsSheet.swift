//
//  CommentsSheet.swift
//  Trop
//
//  Created by 686udjie on 05/11/2026.
//

import SwiftUI

struct CommentsSheet: View {
    let videoId: String
    var songTitle: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.settingsStore) private var settings
    @State private var model = CommentsViewModel()
    @State private var accountState = AccountSheetState.shared
    @State private var isPosting = false
    @State private var postError: String?
    @State private var commentText = ""
    @State private var editingComment: CommentItem?
    @State private var reportingComment: CommentItem?
    @FocusState private var composerFocused: Bool

    var onNavigate: ((DetailRoute) -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sortBar
                    .padding(.horizontal, DesignTokens.screenHPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                inputSection

                content
            }
            .background(Color(.systemBackground))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if accountState.isLoggedIn, composerFocused {
                    emojiRow
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(songTitle.map { "Comments for \($0)" } ?? "Comments")
        }
        .appSheetChrome([.medium, .large])
        .sheet(item: $reportingComment) { comment in
            ReportCommentSheet(comment: comment)
        }
        .task(id: videoId) {
            await model.load(videoId: videoId)
        }
        .task {
            // Populate the composer avatar if the account photo isn't loaded yet.
            if accountState.accountImageUrl == nil {
                await accountState.fetchAccountInfo()
            }
        }
    }

    private var navigationTitle: String {
        if let count = model.totalCountText, !count.isEmpty {
            return String(format: NSLocalizedString("Comments · %@", comment: "Comments sheet title with count"), count)
        }
        return NSLocalizedString("Comments", comment: "Comments sheet title")
    }

    // MARK: - Chrome

    private var sortBar: some View {
        HStack(spacing: 8) {
            ForEach(CommentSort.allCases) { sort in
                let selected = model.sort == sort
                Button {
                    Task { await model.setSort(sort) }
                } label: {
                    Text(LocalizedStringKey(sort.title))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(selected ? settings.accentColor : Color(.secondarySystemBackground))
                        )
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(model.status == .loading || !model.canSwitch(to: sort))
            }
            Spacer()
        }
    }

    /// Composer pinned under the sort bar: avatar + capsule text field (or
    /// a sign-in prompt when logged out), with the post error underneath.
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if accountState.isLoggedIn {
                commentInput
            } else {
                signInBar
            }
            if let postError {
                Text(postError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, DesignTokens.screenHPadding)
            }
        }
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    /// Avatar + capsule text field, matching the inline comment bar —
    /// posting happens from the send button or the return key.
    private var commentInput: some View {
        HStack(spacing: 10) {
            Button {
                openOwnProfile()
            } label: {
                CachedAvatarView(
                    url: accountState.accountImageUrl.flatMap(URL.init(string:)),
                    size: 36
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your profile")

            HStack(spacing: 8) {
                TextField(
                    editingComment == nil ? "Add a comment…" : "Edit comment",
                    text: $commentText,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .disabled(isPosting)
                    .onSubmit { submitComment(commentText) }
                if editingComment != nil {
                    Button(action: cancelEditing) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }
                if isPosting {
                    ProgressView()
                } else if !trimmedComment.isEmpty {
                    Button {
                        submitComment(commentText)
                    } label: {
                        Image(systemName: editingComment == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(settings.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(editingComment == nil ? "Post comment" : "Save comment")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 10)
    }

    /// Logged-out fallback: the same bar, but tapping opens the login sheet.
    private var signInBar: some View {
        Button {
            accountState.isLoginSheetPresented = true
        } label: {
            HStack(spacing: 12) {
                CachedAvatarView(
                    url: accountState.accountImageUrl.flatMap(URL.init(string:)),
                    size: 28
                )
                Text("Add a comment…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a comment")
    }

    /// Quick-react row docked to the keyboard while composing; taps append
    /// straight into the comment text. Emojis spread edge-to-edge.
    private var emojiRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.quickEmojis, id: \.self) { emoji in
                Button {
                    commentText += emoji
                } label: {
                    Text(emoji)
                        .font(.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var trimmedComment: String {
        commentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quickEmojis = ["❤️", "😂", "🎉", "😢", "😮", "😅", "😌"]

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disabled:
            emptyState(
                title: "Comments are disabled for this song",
                systemImage: "bubble.left.and.bubble.right",
                showsRetry: false
            )
        case .error(let message):
            emptyState(
                title: message,
                systemImage: "exclamationmark.triangle",
                showsRetry: true
            )
        case .ready, .loadingMore:
            if model.items.isEmpty {
                emptyState(
                    title: "No comments yet",
                    systemImage: "bubble.left",
                    showsRetry: false
                )
            } else {
                commentsList
            }
        }
    }

    private var commentsList: some View {
        List {
            ForEach(model.items) { comment in
                CommentRowView(
                    comment: comment,
                    accent: settings.accentColor,
                    replies: model.replies[comment.id] ?? [],
                    repliesStatus: model.replyStatus[comment.id] ?? .collapsed,
                    canLoadMoreReplies: model.canLoadMoreReplies(for: comment.id),
                    onToggleReplies: {
                        Task { await model.toggleReplies(for: comment) }
                    },
                    onLoadMoreReplies: {
                        Task { await model.loadMoreReplies(for: comment) }
                    },
                    onAuthorTap: { openAuthor($0) },
                    onVote: { target, direction in
                        vote(target, direction)
                    },
                    onDelete: { model.delete($0) },
                    onEdit: { beginEditing($0) },
                    onReport: { reportingComment = $0 }
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowSeparator(.hidden)
                .onAppear {
                    if comment.id == model.items.last?.id {
                        Task { await model.loadMore() }
                    }
                }
            }

            if model.status == .loadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if model.moreFailed {
                Button("Couldn't load more. Tap to retry.") {
                    Task { await model.loadMore() }
                }
                .font(.footnote)
                .foregroundStyle(settings.accentColor)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func emptyState(title: String, systemImage: String, showsRetry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(title))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsRetry {
                Button("Retry") {
                    Task { await model.load(videoId: videoId) }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func submitComment(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPosting else { return }
        let target = editingComment
        isPosting = true
        postError = nil
        Task {
            do {
                if let target {
                    try await model.edit(target, text: trimmed)
                } else {
                    try await model.postComment(trimmed)
                }
                isPosting = false
                commentText = ""
                editingComment = nil
                composerFocused = false
            } catch {
                isPosting = false
                postError = error.localizedDescription
            }
        }
    }

    private func beginEditing(_ comment: CommentItem) {
        guard comment.editParams != nil else { return }
        editingComment = comment
        commentText = CommentsParser.plainText(for: comment.runs)
        postError = nil
        composerFocused = true
    }

    private func cancelEditing() {
        editingComment = nil
        commentText = ""
        postError = nil
        composerFocused = false
    }

    private func vote(_ comment: CommentItem, _ direction: CommentsViewModel.VoteDirection) {
        guard CommentsViewModel.voteToken(for: comment, direction) != nil else {
            accountState.isLoginSheetPresented = true
            return
        }
        Task { await model.vote(comment, direction) }
    }

    private func openAuthor(_ author: CommentAuthor) {
        guard let channelURL = author.channelURL.flatMap(URL.init(string:)) else { return }
        let prefix = "/channel/"
        let path = channelURL.path
        guard path.hasPrefix(prefix) else {
            openURL(channelURL)
            return
        }
        let browseId = String(path.dropFirst(prefix.count))
        guard !browseId.isEmpty else {
            openURL(channelURL)
            return
        }
        navigate(.artist(browseId: browseId))
    }

    /// Tapping the composer photo opens the viewer's own artist page.
    private func openOwnProfile() {
        guard let channelId = accountState.accountChannelId else { return }
        navigate(.artist(browseId: channelId))
    }

    private func navigate(_ route: DetailRoute) {
        guard let onNavigate else {
            dismiss()
            AppRouter.shared.open(route)
            return
        }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onNavigate(route)
        }
    }
}

// MARK: - Row

private struct CommentRowView: View {
    let comment: CommentItem
    let accent: Color
    let replies: [CommentItem]
    let repliesStatus: CommentsViewModel.RepliesStatus
    let canLoadMoreReplies: Bool
    let onToggleReplies: () -> Void
    let onLoadMoreReplies: () -> Void
    let onAuthorTap: (CommentAuthor) -> Void
    let onVote: (CommentItem, CommentsViewModel.VoteDirection) -> Void
    let onDelete: (CommentItem) -> Void
    let onEdit: (CommentItem) -> Void
    let onReport: (CommentItem) -> Void

    @State private var expanded = false
    @State private var showDeleteConfirm = false

    private var bodyText: String {
        CommentsParser.plainText(for: comment.runs)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                onAuthorTap(comment.author)
            } label: {
                CachedAvatarView(
                    url: comment.author.avatarURL.flatMap(URL.init(string:)),
                    size: 36
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        onAuthorTap(comment.author)
                    } label: {
                        Text(comment.author.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    if comment.author.isVerified || comment.author.isArtist {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !comment.publishedTime.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(comment.publishedTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if comment.isPinned, let pinned = comment.pinnedText, !pinned.isEmpty {
                    Label(pinned, systemImage: "pin.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(bodyText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)

                if !expanded, bodyText.count > 180 {
                    Button("Read more") { expanded = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                }

                HStack(spacing: 16) {
                    Button {
                        onVote(comment, .like)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: comment.voteState == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            if !comment.likeCountText.isEmpty {
                                Text(comment.likeCountText)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(comment.voteState == .liked ? accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(comment.voteState == .liked ? "Unlike" : "Like")

                    Button {
                        onVote(comment, .dislike)
                    } label: {
                        Image(systemName: comment.voteState == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.caption)
                            .foregroundStyle(comment.voteState == .disliked ? accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(comment.voteState == .disliked ? "Remove dislike" : "Dislike")

                    if comment.replyCount > 0 || comment.replyContinuation != nil {
                        Button(action: onToggleReplies) {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left")
                                if !comment.replyCountText.isEmpty {
                                    Text(comment.replyCountText)
                                } else {
                                    Text("Replies")
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                    }

                    if comment.isHearted {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
                .padding(.top, 2)

                repliesSection
            }

            if comment.deleteAction != nil || comment.editParams != nil || comment.reportParams != nil {
                Spacer(minLength: 0)
                commentMenu
            }
        }
    }

    /// Vertical three-dots menu: edit/delete for own comments, Report for
    /// anyone's (only present on signed-in payloads).
    private var commentMenu: some View {
        Menu {
            if comment.editParams != nil {
                Button("Edit comment", systemImage: "pencil") { onEdit(comment) }
            }
            if comment.deleteAction != nil {
                Button("Delete comment", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
            if comment.reportParams != nil {
                Button("Report comment", systemImage: "flag") { onReport(comment) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(90))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Comment options")
        .confirmationDialog(
            "Delete comment?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete comment", role: .destructive) { onDelete(comment) }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder
    private var repliesSection: some View {
        switch repliesStatus {
        case .collapsed:
            EmptyView()
        case .loading:
            ProgressView()
                .padding(.top, 8)
        case .expanded, .loadingMore:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(replies) { reply in
                    CommentReplyRow(
                        comment: reply,
                        accent: accent,
                        onAuthorTap: onAuthorTap,
                        onVote: onVote,
                        onDelete: onDelete,
                        onEdit: onEdit,
                        onReport: onReport
                    )
                }
                if repliesStatus == .loadingMore {
                    ProgressView()
                } else if canLoadMoreReplies {
                    Button("Show more replies", action: onLoadMoreReplies)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
            .padding(.leading, 4)
        case .failed:
            Button("Couldn't load replies. Tap to retry.", action: onToggleReplies)
                .font(.caption)
                .foregroundStyle(accent)
                .padding(.top, 8)
        }
    }
}

private struct CommentReplyRow: View {
    let comment: CommentItem
    let accent: Color
    let onAuthorTap: (CommentAuthor) -> Void
    let onVote: (CommentItem, CommentsViewModel.VoteDirection) -> Void
    let onDelete: (CommentItem) -> Void
    let onEdit: (CommentItem) -> Void
    let onReport: (CommentItem) -> Void
    @State private var expanded = false
    @State private var showDeleteConfirm = false

    private var bodyText: String {
        CommentsParser.plainText(for: comment.runs)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onAuthorTap(comment.author)
            } label: {
                CachedAvatarView(
                    url: comment.author.avatarURL.flatMap(URL.init(string:)),
                    size: 28
                )
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        onAuthorTap(comment.author)
                    } label: {
                        Text(comment.author.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    if !comment.publishedTime.isEmpty {
                        Text(comment.publishedTime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(bodyText)
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 3)
                if !expanded, bodyText.count > 140 {
                    Button("Read more") { expanded = true }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    Button {
                        onVote(comment, .like)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: comment.voteState == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            if !comment.likeCountText.isEmpty {
                                Text(comment.likeCountText)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(comment.voteState == .liked ? accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(comment.voteState == .liked ? "Unlike" : "Like")

                    Button {
                        onVote(comment, .dislike)
                    } label: {
                        Image(systemName: comment.voteState == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.caption2)
                            .foregroundStyle(comment.voteState == .disliked ? accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(comment.voteState == .disliked ? "Remove dislike" : "Dislike")
                }
            }

            if comment.deleteAction != nil || comment.editParams != nil || comment.reportParams != nil {
                Spacer(minLength: 0)
                replyMenu
            }
        }
    }

    private var replyMenu: some View {
        Menu {
            if comment.editParams != nil {
                Button("Edit comment", systemImage: "pencil") { onEdit(comment) }
            }
            if comment.deleteAction != nil {
                Button("Delete reply", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
            if comment.reportParams != nil {
                Button("Report comment", systemImage: "flag") { onReport(comment) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(90))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Reply options")
        .confirmationDialog(
            "Delete reply?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete reply", role: .destructive) { onDelete(comment) }
        } message: {
            Text("This can't be undone.")
        }
    }
}

// MARK: - View model

@MainActor
@Observable
final class CommentsViewModel {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case loadingMore
        case disabled
        case error(String)
    }

    enum RepliesStatus: Equatable {
        case collapsed
        case loading
        case expanded
        case loadingMore
        case failed
    }

    private(set) var status: Status = .idle
    private(set) var items: [CommentItem] = []
    private(set) var sort: CommentSort = .top
    private(set) var totalCountText: String?
    private(set) var moreFailed = false
    private(set) var replies: [String: [CommentItem]] = [:]
    private(set) var replyStatus: [String: RepliesStatus] = [:]
    private(set) var createCommentParams: String?

    private var topToken: String?
    private var newestToken: String?
    private var nextPageToken: String?
    private var replyContinuations: [String: String] = [:]
    private var loadedVideoId: String?
    private var loadTask: Task<Void, Never>?

    func canSwitch(to sort: CommentSort) -> Bool {
        switch sort {
        case .top: return topToken != nil || self.sort == .top
        case .newest: return newestToken != nil
        }
    }

    func canLoadMoreReplies(for commentId: String) -> Bool {
        replyContinuations[commentId] != nil
    }

    func load(videoId: String) async {
        loadTask?.cancel()
        let task = Task { await self.performLoad(videoId: videoId) }
        loadTask = task
        await task.value
    }

    func setSort(_ sort: CommentSort) async {
        guard sort != self.sort else { return }
        let token = sort == .top ? topToken : newestToken
        guard let token else { return }

        self.sort = sort
        items = []
        nextPageToken = nil
        moreFailed = false
        replies = [:]
        replyStatus = [:]
        replyContinuations = [:]
        status = .loading

        do {
            let page = try await CommentsService.shared.loadPage(continuation: token)
            guard !Task.isCancelled else { return }
            apply(page: page, replacing: true)
            status = .ready
        } catch {
            guard !Task.isCancelled else { return }
            status = .error(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard status == .ready, let token = nextPageToken else { return }
        status = .loadingMore
        moreFailed = false
        do {
            let page = try await CommentsService.shared.loadPage(continuation: token)
            guard !Task.isCancelled else { return }
            apply(page: page, replacing: false)
            status = .ready
        } catch {
            guard !Task.isCancelled else { return }
            status = .ready
            moreFailed = true
        }
    }

    func toggleReplies(for comment: CommentItem) async {
        let current = replyStatus[comment.id] ?? .collapsed
        switch current {
        case .expanded, .loadingMore:
            replyStatus[comment.id] = .collapsed
            return
        case .loading:
            return
        case .collapsed, .failed:
            break
        }

        if let existing = replies[comment.id], !existing.isEmpty {
            replyStatus[comment.id] = .expanded
            return
        }

        guard let token = comment.replyContinuation ?? replyContinuations[comment.id] else {
            replyStatus[comment.id] = .collapsed
            return
        }

        replyStatus[comment.id] = .loading
        do {
            let page = try await CommentsService.shared.loadReplies(continuation: token)
            guard !Task.isCancelled else { return }
            replies[comment.id] = page.items
            replyContinuations[comment.id] = page.nextPageToken
            replyStatus[comment.id] = .expanded
        } catch {
            guard !Task.isCancelled else { return }
            replyStatus[comment.id] = .failed
        }
    }

    func loadMoreReplies(for comment: CommentItem) async {
        guard let token = replyContinuations[comment.id] else { return }
        replyStatus[comment.id] = .loadingMore
        do {
            let page = try await CommentsService.shared.loadReplies(continuation: token)
            guard !Task.isCancelled else { return }
            var merged = replies[comment.id] ?? []
            let known = Set(merged.map(\.id))
            merged.append(contentsOf: page.items.filter { !known.contains($0.id) })
            replies[comment.id] = merged
            replyContinuations[comment.id] = page.nextPageToken
            replyStatus[comment.id] = .expanded
        } catch {
            guard !Task.isCancelled else { return }
            replyStatus[comment.id] = .expanded
        }
    }

    // MARK: - Voting

    enum VoteDirection {
        case like
        case dislike
    }

    static func voteToken(for comment: CommentItem, _ direction: VoteDirection) -> String? {
        switch direction {
        case .like:
            return comment.voteState == .liked ? comment.unlikeAction : comment.likeAction
        case .dislike:
            return comment.voteState == .disliked ? comment.undislikeAction : comment.dislikeAction
        }
    }

    func vote(_ comment: CommentItem, _ direction: VoteDirection) async {
        guard let token = Self.voteToken(for: comment, direction) else { return }
        let nextState: CommentVoteState
        switch direction {
        case .like: nextState = comment.voteState == .liked ? .indifferent : .liked
        case .dislike: nextState = comment.voteState == .disliked ? .indifferent : .disliked
        }
        let previousState = comment.voteState
        let delta = (nextState == .liked ? 1 : 0) - (previousState == .liked ? 1 : 0)

        // Optimistic: the action response carries no framework updates.
        applyVote(id: comment.id, to: nextState, delta: delta)
        do {
            let succeeded = try await CommentsService.shared.performCommentAction(action: token)
            guard !succeeded else { return }
            applyVote(id: comment.id, to: previousState, delta: -delta)
        } catch {
            applyVote(id: comment.id, to: previousState, delta: -delta)
        }
    }

    private func applyVote(id: String, to state: CommentVoteState, delta: Int) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = Self.voted(items[index], to: state, delta: delta)
        }
        for (key, list) in replies {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            var updated = list
            updated[index] = Self.voted(updated[index], to: state, delta: delta)
            replies[key] = updated
        }
    }

    private static func voted(_ comment: CommentItem, to state: CommentVoteState, delta: Int) -> CommentItem {
        var updated = comment
        updated.voteState = state
        if delta != 0 {
            updated.likeCountText = adjustedLikeCount(comment.likeCountText, delta: delta)
        }
        return updated
    }

    private static func adjustedLikeCount(_ text: String, delta: Int) -> String {
        guard let value = compactCountValue(text) else { return text }
        return compactCountText(max(0, value + delta))
    }

    private static func compactCountValue(_ text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard let last = cleaned.last, "KMB".contains(last) else {
            return Int(cleaned.replacingOccurrences(of: ",", with: ""))
        }
        let number = String(cleaned.dropLast()).replacingOccurrences(of: ",", with: "")
        guard let parsed = Double(number) else { return nil }
        switch last {
        case "K": return Int((parsed * 1_000).rounded())
        case "M": return Int((parsed * 1_000_000).rounded())
        default: return Int((parsed * 1_000_000_000).rounded())
        }
    }

    private static func compactCountText(_ value: Int) -> String {
        switch value {
        case ..<1_000: return String(value)
        case ..<1_000_000: return compactDecimal(Double(value) / 1_000) + "K"
        case ..<1_000_000_000: return compactDecimal(Double(value) / 1_000_000) + "M"
        default: return compactDecimal(Double(value) / 1_000_000_000) + "B"
        }
    }

    private static func compactDecimal(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    // MARK: - Deleting

    /// Removes the comment optimistically and replays its server-issued
    /// delete token; restores the row (and the total count) if YouTube
    /// rejects the action.
    func delete(_ comment: CommentItem) {
        guard let token = comment.deleteAction else { return }
        guard let removal = removeForDelete(id: comment.id) else { return }
        Task {
            do {
                let succeeded = try await CommentsService.shared.performCommentAction(action: token)
                guard !succeeded else { return }
                restore(removal)
            } catch {
                restore(removal)
            }
        }
    }

    func edit(_ comment: CommentItem, text: String) async throws {
        guard let params = comment.editParams else {
            throw CommentsError.rejected(
                NSLocalizedString("This comment can't be edited.", comment: "")
            )
        }
        try await CommentsService.shared.updateComment(params: params, text: text)
        updateEditedComment(id: comment.id, text: text)
    }

    private func updateEditedComment(id: String, text: String) {
        func edited(_ comment: CommentItem) -> CommentItem {
            var updated = comment
            updated.runs = [.text(text)]
            return updated
        }

        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = edited(items[index])
        }
        for (key, list) in replies {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            var updated = list
            updated[index] = edited(updated[index])
            replies[key] = updated
        }
    }

    private struct PendingRemoval {
        let comment: CommentItem
        let index: Int
        let parentKey: String?
        let totalCountText: String?
    }

    private func removeForDelete(id: String) -> PendingRemoval? {
        if let index = items.firstIndex(where: { $0.id == id }) {
            let removed = items.remove(at: index)
            let previousTotal = totalCountText
            if let previousTotal, let value = Self.compactCountValue(previousTotal) {
                totalCountText = Self.formattedTotal(value - 1)
            }
            return PendingRemoval(comment: removed, index: index, parentKey: nil, totalCountText: previousTotal)
        }
        for (key, list) in replies {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            var updated = list
            let removed = updated.remove(at: index)
            replies[key] = updated
            return PendingRemoval(comment: removed, index: index, parentKey: key, totalCountText: nil)
        }
        return nil
    }

    private func restore(_ removal: PendingRemoval) {
        if let key = removal.parentKey {
            var list = replies[key] ?? []
            guard removal.index <= list.count else { return }
            list.insert(removal.comment, at: removal.index)
            replies[key] = list
        } else {
            guard removal.index <= items.count else { return }
            items.insert(removal.comment, at: removal.index)
        }
        if let count = removal.totalCountText { totalCountText = count }
    }

    /// Comment totals render as grouped digits ("2,661"), not the compact
    /// K-notation used for like counts.
    private static func formattedTotal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
    }

    // MARK: - Composer

    /// Posts a top-level comment, then refreshes the list so the new
    /// comment arrives with its real author, tokens, and counts.
    func postComment(_ text: String) async throws {
        guard let params = createCommentParams else {
            throw CommentsError.rejected(
                NSLocalizedString("Comments haven't loaded yet — try again in a moment", comment: "")
            )
        }
        try await CommentsService.shared.postComment(params: params, text: text)
        await refreshAfterPost()
    }

    private func refreshAfterPost() async {
        guard let videoId = loadedVideoId else { return }
        do {
            let page = try await CommentsService.shared.loadInitial(videoId: videoId)
            guard !Task.isCancelled else { return }
            apply(page: page, replacing: true)
        } catch {
            // The comment is posted; a stale list beats an error flash.
        }
    }

    private func performLoad(videoId: String) async {
        status = .loading
        items = []
        totalCountText = nil
        topToken = nil
        newestToken = nil
        nextPageToken = nil
        moreFailed = false
        replies = [:]
        replyStatus = [:]
        replyContinuations = [:]
        createCommentParams = nil
        sort = .top
        loadedVideoId = videoId

        do {
            let page = try await CommentsService.shared.loadInitial(videoId: videoId)
            guard !Task.isCancelled, loadedVideoId == videoId else { return }
            apply(page: page, replacing: true)
            status = .ready
        } catch is CancellationError {
            return
        } catch CommentsError.disabled {
            guard loadedVideoId == videoId else { return }
            status = .disabled
        } catch {
            guard loadedVideoId == videoId else { return }
            status = .error(error.localizedDescription)
        }
    }

    private func apply(page: CommentsPage, replacing: Bool) {
        if replacing {
            items = page.items
        } else {
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
        }
        nextPageToken = page.nextPageToken
        if let top = page.sortTokens[.top] { topToken = top }
        if let newest = page.sortTokens[.newest] { newestToken = newest }
        if let count = page.totalCountText { totalCountText = count }
        if let params = page.createCommentParams { createCommentParams = params }

        for item in page.items {
            if let token = item.replyContinuation {
                replyContinuations[item.id] = token
            }
        }
    }
}
