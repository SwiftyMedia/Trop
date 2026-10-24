//
//  NavigationTitleView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

struct NavigationTitleView: View {
    var title: String
    var label: String?
    var thumbnailUrl: String?
    var onClick: (() -> Void)?

    var body: some View {
        Button(
            action: { onClick?() },
            label: {
                HStack(spacing: 10) {
                    if let thumbnailUrl {
                        AsyncImageView(url: thumbnailUrl)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        if let label {
                            Text(LocalizedStringKey(label))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text(LocalizedStringKey(title))
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if onClick != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        )
        .buttonStyle(.plain)
    }
}
