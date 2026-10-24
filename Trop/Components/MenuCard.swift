//
//  MenuCard.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import SwiftUI

/// Standard chrome for menu sheets: NavigationStack + padded card column on
/// the grouped background with medium/large detents and a drag indicator.
/// Content needing `navigationDestination` should wrap itself in a `Group`
/// carrying that modifier (it must live inside the NavigationStack).
struct SheetChrome<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    content
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Rounded grouped-background card stacking menu rows with no spacing.
struct MenuCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.sheetRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// Tappable menu row: accent icon + title + optional subtitle.
struct MenuRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(icon: icon, title: title, subtitle: subtitle, destructive: destructive)
        }
        .buttonStyle(.plain)
    }
}

/// The label half of `MenuRow`, for rows embedded in a `NavigationLink`.
struct MenuRowLabel: View {
    @Environment(\.settingsStore) private var settings

    let icon: String
    let title: String
    var subtitle: String?
    var destructive: Bool = false

    var body: some View {
        HStack(spacing: DesignTokens.menuRowSpacing) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(destructive ? Color.red : settings.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
