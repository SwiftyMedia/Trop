//
//  TabHeaderView.swift
//  Trop
//
//  Created by 686udjie on 18/08/2026.
//

import SwiftUI

/// Shared large-title header with history and account buttons,
/// used by the Home and Library tabs.
struct TabHeaderView: View {
    let title: String
    var accountIsLoggedIn: Bool = false
    var accountImageUrl: String?
    var onHistory: () -> Void
    var onAccount: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(LocalizedStringKey(title))
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            HStack(spacing: 10) {
                Button(action: onHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("History")

                AccountButtonView(
                    isLoggedIn: accountIsLoggedIn,
                    accountImageUrl: accountImageUrl,
                    onTap: onAccount
                )
                .accessibilityLabel("Account")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
