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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sortBar
                    .padding(.horizontal, DesignTokens.screenHPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                guidelinesBanner
                    .padding(.horizontal, DesignTokens.screenHPadding)
                    .padding(.bottom, 12)

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
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.title2)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                composerBar
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(songTitle.map { "Comments for \($0)" } ?? "Comments")
        }
        .appSheetChrome([.medium, .large])
        .task(id: videoId) {
            await model.load(videoId: videoId)
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
                                .fill(selected ? Color.primary : Color(.secondarySystemBackground))
                        )
                        .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(model.status == .loading || !model.canSwitch(to: sort))
            }
            Spacer()
        }
    }

    private var guidelinesBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Remember to keep comments respectful and follow community guidelines.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var composerBar: some View {
        Button {
            openOnYouTube()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
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
            .background(.bar)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a comment on YouTube")
    }

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
                    }
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

    private func openOnYouTube() {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return }
        openURL(url)
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

    @State private var expanded = false

    private var bodyText: String {
        CommentsParser.plainText(for: comment.runs)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedAvatarView(
                url: comment.author.avatarURL.flatMap(URL.init(string:)),
                size: 36
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
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
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup")
                        if !comment.likeCountText.isEmpty {
                            Text(comment.likeCountText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Image(systemName: "hand.thumbsdown")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                    CommentReplyRow(comment: reply, accent: accent)
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
    @State private var expanded = false

    private var bodyText: String {
        CommentsParser.plainText(for: comment.runs)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAvatarView(
                url: comment.author.avatarURL.flatMap(URL.init(string:)),
                size: 28
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
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
                if !comment.likeCountText.isEmpty {
                    Label(comment.likeCountText, systemImage: "hand.thumbsup")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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

        for item in page.items {
            if let token = item.replyContinuation {
                replyContinuations[item.id] = token
            }
        }
    }
}
