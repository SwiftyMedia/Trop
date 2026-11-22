//
//  YouTubeGridItemView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

struct YouTubeGridItemView: View {
    var item: YTItem
    var onTap: () -> Void

    @State private var durations = DurationResolver()
    private let artworkSize: CGFloat = 160

    private var videoId: String? {
        switch item {
        case .song(let s): return s.videoId
        case .episode(let e): return e.videoId
        default: return nil
        }
    }

    private var subtitleText: String {
        switch item {
        case .song(let s):
            return s.subtitleLine(duration: durations.effectiveDuration(known: s.duration))
        case .episode(let e):
            return e.toSongItem().subtitleLine(duration: durations.effectiveDuration(known: e.duration))
        case .album(let a):
            let names = a.artists.map(\.name)
            return names.isEmpty ? "" : names.joined(separator: ", ")
        default:
            return ""
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImageView(url: item.thumbnailUrl)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: artworkSize, height: 220, alignment: .top)
        }
        .buttonStyle(.plain)
        .task {
            guard let vid = videoId else { return }
            let known: Int
            switch item {
            case .song(let s): known = s.duration
            case .episode(let e): known = e.duration
            default: known = 0
            }
            await durations.resolve(videoId: vid, knownDuration: known)
        }
        .onReceive(NotificationCenter.default.publisher(for: .durationDidUpdate)) { notification in
            durations.handleUpdate(notification, videoId: videoId)
        }
    }
}

struct YouTubeListItemView: View {
    @Environment(SettingsStore.self) private var settings
    var item: YTItem
    var onTap: () -> Void
    var onNavigate: ((DetailRoute) -> Void)?

    private var songItem: SongItem? {
        switch item {
        case .song(let s): return s
        case .episode(let e): return e.toSongItem()
        default: return nil
        }
    }

    var body: some View {
        if let song = songItem {
            SongRowView(
                song: song,
                artSize: 48,
                onTap: onTap,
                onNavigate: onNavigate
            )
        } else {
            HStack(spacing: 12) {
                AsyncImageView(url: item.thumbnailUrl)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(albumSubtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let url = item.webUrl {
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        VerticalEllipsis(font: .body.weight(.bold))
                            .foregroundStyle(settings.accentColor)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var albumSubtitleText: String {
        if case .album(let a) = item {
            return a.artists.map(\.name).joined(separator: ", ")
        }
        return ""
    }
}
