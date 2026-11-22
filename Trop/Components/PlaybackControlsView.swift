//
//  PlaybackControlsView.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Shuffle / play / more circular buttons shared by every detail header.
/// Canonicalizes on the PlaylistHeaderView styling (48/64pt, grouped
/// background, accent glow shadow).
struct PlaybackControlsView: View {
    var accent: Color = .accentColor
    var showsShuffle: Bool = true
    var showsMore: Bool = false
    var onPlay: () -> Void
    var onShuffle: () -> Void = {}
    var onMore: () -> Void = {}

    var body: some View {
        HStack(spacing: 20) {
            if showsShuffle {
                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle")
            }

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(accent))
                    .shadow(color: accent.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play all")

            if showsMore {
                Button(action: onMore) {
                    VerticalEllipsis(font: .title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More options")
            }
        }
        .padding(.top, 4)
    }
}
