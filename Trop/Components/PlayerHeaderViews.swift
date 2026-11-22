//
//  PlayerHeaderViews.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Title + artist marquee block shared by the FullPlayer, Queue and Lyrics
/// header rows.
struct PlayerTitleBlock: View {
    var title: String
    var artist: String
    var spacing: CGFloat = 2
    var titleFont: Font = .body.weight(.semibold)
    var titleHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            MarqueeText(
                text: title,
                font: titleFont,
                frameHeight: titleHeight
            )

            if !artist.isEmpty {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }
}

/// White heart toggle for player surfaces (FullPlayer, Queue).
struct PlayerLikeButton: View {
    var isLiked: Bool
    var activeColor: Color = .red
    var inactiveColor: Color = .white
    var fontSize: CGFloat = 17
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(isLiked ? activeColor : inactiveColor)
                .frame(width: 36, height: 36)
        }
    }
}

/// White ⋮ button for player surfaces. The options sheet stays owned by the caller.
struct PlayerOptionsButton: View {
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VerticalEllipsis(font: .system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Song options")
    }
}
