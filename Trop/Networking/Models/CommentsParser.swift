//
//  CommentsParser.swift
//  Trop
//
//  Created by 686udjie on 05/11/2026.
//

import Foundation

enum CommentsParser {
    // MARK: - Token discovery

    /// Pulls the first comments-section continuation from a WEB `/next` watch response.
    static func findInitialCommentsToken(in json: [String: Any]) -> String? {
        let contents =
            dictionary(json, "contents", "twoColumnWatchNextResults", "results", "results")?["contents"] as? [[String: Any]]
            ?? []

        for item in contents {
            guard let section = item["itemSectionRenderer"] as? [String: Any] else { continue }
            let identifier = (section["sectionIdentifier"] as? String)
                ?? (section["targetId"] as? String)
                ?? ""
            guard identifier == "comment-item-section" || identifier == "comments-section" else { continue }
            if let token = continuationToken(in: section["contents"]) {
                return token
            }
        }

        for item in contents {
            guard let section = item["itemSectionRenderer"] as? [String: Any],
                  let token = continuationToken(in: section["contents"]),
                  token.count > 50 else { continue }
            return token
        }

        // Music-host / alternate layouts: walk the tree for a comments section id.
        return deepFindCommentsToken(in: json)
    }

    // MARK: - Pages

    static func parseCommentsPage(_ json: [String: Any]) -> CommentsPage {
        let entities = buildEntities(from: json)
        var items: [CommentItem] = []
        var nextPageToken: String?
        var totalCountText: String?
        var sortTokens: [CommentSort: String] = [:]

        for action in collectActions(from: json) {
            if let thread = action["commentThreadRenderer"] as? [String: Any] {
                let viewModel = viewModel(of: thread)
                let commentId = viewModel?["commentId"] as? String
                let entity = commentId.flatMap { entities.comments[$0] }
                guard let base = makeComment(
                    entity: entity,
                    viewModel: viewModel,
                    toolbarStates: entities.toolbarStates,
                    isThread: true
                ) else { continue }

                let replies = dictionary(thread, "replies", "commentRepliesRenderer")
                let replyContinuation = (replies?["contents"] as? [[String: Any]])?
                    .compactMap { continuationToken(in: $0) }
                    .first

                var item = base
                item.isPinned = (viewModel?["pinnedText"] as? String)?.isEmpty == false
                item.pinnedText = viewModel?["pinnedText"] as? String
                let toolbar = entity?["toolbar"] as? [String: Any]
                item.replyCount = parseCompactNumber(toolbar?["replyCount"])
                item.replyCountText = stringValue(toolbar?["replyCount"]) ?? ""
                item.replyContinuation = replyContinuation
                items.append(item)
            } else if let token = continuationToken(in: action) {
                nextPageToken = token
            } else if let header = action["commentsHeaderRenderer"] as? [String: Any] {
                totalCountText = extractCountText(from: header) ?? totalCountText
                if let subItems = dictionary(header, "sortMenu", "sortFilterSubMenuRenderer")?["subMenuItems"] as? [[String: Any]] {
                    if let top = continuationCommandToken(in: subItems[safe: 0]) {
                        sortTokens[.top] = top
                    }
                    if let newest = continuationCommandToken(in: subItems[safe: 1]) {
                        sortTokens[.newest] = newest
                    }
                }
            }
        }

        return CommentsPage(
            items: items,
            nextPageToken: nextPageToken,
            sortTokens: sortTokens,
            totalCountText: totalCountText
        )
    }

    static func parseRepliesPage(_ json: [String: Any]) -> CommentRepliesPage {
        let entities = buildEntities(from: json)
        var items: [CommentItem] = []
        var seen = Set<String>()
        var nextPageToken: String?

        func push(_ viewModel: [String: Any]?) {
            guard let id = viewModel?["commentId"] as? String, !seen.contains(id) else { return }
            let entity = entities.comments[id]
            guard var reply = makeComment(
                entity: entity,
                viewModel: viewModel,
                toolbarStates: entities.toolbarStates,
                isThread: false
            ) else { return }
            reply.replyCount = 0
            reply.replyCountText = ""
            reply.replyContinuation = nil
            seen.insert(id)
            items.append(reply)
        }

        for action in collectActions(from: json) {
            if action["commentViewModel"] != nil {
                push(viewModel(of: action))
            } else if let thread = action["commentThreadRenderer"] as? [String: Any] {
                push(viewModel(of: thread))
            } else if let token = continuationToken(in: action) {
                nextPageToken = token
            }
        }

        if items.isEmpty {
            for entity in entities.comments.values {
                let props = entity["properties"] as? [String: Any]
                let level = props?["replyLevel"] as? Int ?? Int(stringValue(props?["replyLevel"]) ?? "") ?? 0
                guard level >= 1, let id = props?["commentId"] as? String else { continue }
                push(["commentId": id])
            }
        }

        return CommentRepliesPage(items: items, nextPageToken: nextPageToken)
    }

    // MARK: - Entities

    private struct Entities {
        var comments: [String: [String: Any]]
        var toolbarStates: [String: [String: Any]]
    }

    private static func buildEntities(from json: [String: Any]) -> Entities {
        let mutations =
            dictionary(json, "frameworkUpdates", "entityBatchUpdate")?["mutations"] as? [[String: Any]]
            ?? []
        var comments: [String: [String: Any]] = [:]
        var toolbarStates: [String: [String: Any]] = [:]

        for mutation in mutations {
            guard let payload = mutation["payload"] as? [String: Any] else { continue }
            if let comment = payload["commentEntityPayload"] as? [String: Any],
               let id = dictionary(comment, "properties")?["commentId"] as? String {
                comments[id] = comment
            }
            if let toolbar = payload["engagementToolbarStateEntityPayload"] as? [String: Any] {
                let key = (toolbar["key"] as? String) ?? (mutation["entityKey"] as? String)
                if let key { toolbarStates[key] = toolbar }
            }
        }
        return Entities(comments: comments, toolbarStates: toolbarStates)
    }

    private static func collectActions(from json: [String: Any]) -> [[String: Any]] {
        let endpoints = json["onResponseReceivedEndpoints"] as? [[String: Any]] ?? []
        var out: [[String: Any]] = []
        for endpoint in endpoints {
            if let append = dictionary(endpoint, "appendContinuationItemsAction")?["continuationItems"] as? [[String: Any]] {
                out.append(contentsOf: append)
            }
            if let reload = dictionary(endpoint, "reloadContinuationItemsCommand")?["continuationItems"] as? [[String: Any]] {
                out.append(contentsOf: reload)
            }
        }
        return out
    }

    private static func viewModel(of node: [String: Any]) -> [String: Any]? {
        if let nested = dictionary(node, "commentViewModel", "commentViewModel") {
            return nested
        }
        return node["commentViewModel"] as? [String: Any]
    }

    private static func makeComment(
        entity: [String: Any]?,
        viewModel: [String: Any]?,
        toolbarStates: [String: [String: Any]],
        isThread: Bool
    ) -> CommentItem? {
        guard let entity,
              let props = entity["properties"] as? [String: Any],
              let id = props["commentId"] as? String,
              let content = props["content"] as? [String: Any],
              content["content"] is String else { return nil }

        let toolbar = entity["toolbar"] as? [String: Any] ?? [:]
        let stateKey = (viewModel?["toolbarStateKey"] as? String)
            ?? (props["toolbarStateKey"] as? String)
        let state = stateKey.flatMap { toolbarStates[$0] }
        let likeText = stringValue(toolbar["likeCountNotliked"])
            ?? stringValue(toolbar["likeCountLiked"])
            ?? ""

        return CommentItem(
            id: id,
            author: makeAuthor(from: entity),
            runs: toRuns(content),
            publishedTime: stringValue(props["publishedTime"]) ?? "",
            likeCountText: likeText,
            isHearted: (state?["heartState"] as? String) == "TOOLBAR_HEART_STATE_HEARTED",
            isPinned: false,
            pinnedText: nil,
            replyCount: isThread ? parseCompactNumber(toolbar["replyCount"]) : 0,
            replyCountText: isThread ? (stringValue(toolbar["replyCount"]) ?? "") : "",
            replyContinuation: nil
        )
    }

    private static func makeAuthor(from entity: [String: Any]) -> CommentAuthor {
        let author = entity["author"] as? [String: Any] ?? [:]
        let channelPath =
            dictionary(author, "channelCommand", "innertubeCommand", "commandMetadata", "webCommandMetadata")?["url"] as? String
            ?? {
                if let channelId = author["channelId"] as? String, !channelId.isEmpty {
                    return "/channel/\(channelId)"
                }
                return nil
            }()

        return CommentAuthor(
            name: stringValue(author["displayName"]) ?? "",
            avatarURL: stringValue(author["avatarThumbnailUrl"]),
            channelURL: channelPath.map(absoluteYouTubeURL),
            isCreator: author["isCreator"] as? Bool ?? false,
            isVerified: author["isVerified"] as? Bool ?? false,
            isArtist: author["isArtist"] as? Bool ?? false
        )
    }

    static func plainText(for runs: [CommentTextRun]) -> String {
        runs.map { run in
            switch run {
            case .text(let text), .link(text: let text, _), .timestamp(text: let text, _, _):
                return text
            }
        }.joined()
    }

    // MARK: - Text runs

    private static func toRuns(_ content: [String: Any]) -> [CommentTextRun] {
        let text = stringValue(content["content"]) ?? ""
        let commands = content["commandRuns"] as? [[String: Any]] ?? []
        guard !commands.isEmpty else {
            return text.isEmpty ? [] : [.text(text)]
        }

        let sorted = commands
            .compactMap { command -> (start: Int, length: Int, command: [String: Any])? in
                guard let start = command["startIndex"] as? Int,
                      let length = command["length"] as? Int else { return nil }
                return (start, length, command)
            }
            .sorted { $0.start < $1.start }

        var runs: [CommentTextRun] = []
        var cursor = 0
        let utf16 = Array(text.utf16)

        for entry in sorted {
            guard entry.start >= cursor, entry.start + entry.length <= utf16.count else { continue }
            if entry.start > cursor {
                runs.append(.text(utf16String(utf16[cursor..<entry.start])))
            }
            let slice = utf16String(utf16[entry.start..<(entry.start + entry.length)])
            let innertube = dictionary(entry.command, "onTap", "innertubeCommand")
            runs.append(runFromCommand(text: slice, command: innertube))
            cursor = entry.start + entry.length
        }
        if cursor < utf16.count {
            runs.append(.text(utf16String(utf16[cursor..<utf16.count])))
        }
        return runs.filter {
            switch $0 {
            case .text(let t): return !t.isEmpty
            default: return true
            }
        }
    }

    private static func runFromCommand(text: String, command: [String: Any]?) -> CommentTextRun {
        if let watch = command?["watchEndpoint"] as? [String: Any],
           let seconds = watch["startTimeSeconds"] as? Double
            ?? (watch["startTimeSeconds"] as? Int).map(Double.init) {
            return .timestamp(text: text, seconds: seconds, videoId: watch["videoId"] as? String)
        }

        let urlString =
            dictionary(command ?? [:], "urlEndpoint")?["url"] as? String
            ?? dictionary(command ?? [:], "commandMetadata", "webCommandMetadata")?["url"] as? String
        if let urlString,
           let url = URL(string: unwrapRedirect(absoluteYouTubeURL(urlString))) {
            return .link(text: text, url: url)
        }
        return .text(text)
    }

    // MARK: - Helpers

    private static func continuationToken(in node: Any?) -> String? {
        if let dict = node as? [String: Any] {
            if let token =
                dictionary(dict, "continuationItemRenderer", "continuationEndpoint", "continuationCommand")?["token"] as? String
                ?? dictionary(dict, "continuationItemRenderer", "button", "buttonRenderer", "command", "continuationCommand")?["token"] as? String {
                return token
            }
            return nil
        }
        if let array = node as? [[String: Any]] {
            for item in array {
                if let token = continuationToken(in: item) { return token }
            }
        }
        return nil
    }

    private static func continuationCommandToken(in item: [String: Any]?) -> String? {
        dictionary(item ?? [:], "serviceEndpoint", "continuationCommand")?["token"] as? String
    }

    private static func extractCountText(from header: [String: Any]) -> String? {
        if let runs = dictionary(header, "countText")?["runs"] as? [[String: Any]] {
            if let match = runs
                .compactMap({ stringValue($0["text"])?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
                return match
            }
        }
        return textOf(header["commentsCount"]) ?? textOf(header["countText"])
    }

    private static func textOf(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { stringValue($0["text"]) }.joined()
        }
        return nil
    }

    private static func parseCompactNumber(_ value: Any?) -> Int {
        let raw = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return 0 }
        let pattern = #"^([\d.,\s\u00a0]+)\s*([kKmM])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else {
            return Int(raw.filter(\.isNumber)) ?? 0
        }

        let digitsRange = Range(match.range(at: 1), in: raw)
        let suffixRange = Range(match.range(at: 2), in: raw)
        guard let digitsRange else { return 0 }
        let digits = String(raw[digitsRange])
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")

        let number: Double
        if suffixRange != nil {
            number = Double(digits.replacingOccurrences(of: ",", with: ".")) ?? 0
        } else {
            number = Double(digits.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: ".", with: "")) ?? 0
        }
        guard number.isFinite else { return 0 }

        let multiplier: Double
        if let suffixRange {
            switch raw[suffixRange].lowercased() {
            case "k": multiplier = 1_000
            case "m": multiplier = 1_000_000
            default: multiplier = 1
            }
        } else {
            multiplier = 1
        }
        return Int((number * multiplier).rounded())
    }

    private static func absoluteYouTubeURL(_ path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        return "https://www.youtube.com\(path.hasPrefix("/") ? "" : "/")\(path)"
    }

    private static func unwrapRedirect(_ urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host,
              host.hasSuffix("youtube.com"),
              url.path == "/redirect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "q" })?.value else {
            return urlString
        }
        return target
    }

    private static func deepFindCommentsToken(in value: Any, depth: Int = 0) -> String? {
        guard depth < 12 else { return nil }
        if let dict = value as? [String: Any] {
            let identifier = (dict["sectionIdentifier"] as? String) ?? (dict["targetId"] as? String)
            if identifier == "comment-item-section" || identifier == "comments-section",
               let token = continuationToken(in: dict["contents"]) {
                return token
            }
            for nested in dict.values {
                if let token = deepFindCommentsToken(in: nested, depth: depth + 1) {
                    return token
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let token = deepFindCommentsToken(in: nested, depth: depth + 1) {
                    return token
                }
            }
        }
        return nil
    }

    private static func dictionary(_ root: [String: Any], _ path: String...) -> [String: Any]? {
        var current: Any? = root
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func utf16String(_ slice: ArraySlice<UInt16>) -> String {
        guard !slice.isEmpty else { return "" }
        var units = Array(slice)
        return units.withUnsafeBufferPointer { buffer in
            String(utf16CodeUnits: buffer.baseAddress!, count: buffer.count)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
