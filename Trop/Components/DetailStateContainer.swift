//
//  DetailStateContainer.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Centered spinner + message placeholder used while content loads.
struct LoadingStateView: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

/// Loading / error / empty / content tri-state shared by the detail screens.
/// `noun` derives the standard copy ("Loading album…", "Couldn't load album",
/// "No album data", "Could not parse album details").
struct DetailStateContainer<Data, Content: View>: View {
    var isLoading: Bool
    var error: Error?
    var data: Data?
    var noun: String
    var emptyIcon: String
    @ViewBuilder var content: (Data) -> Content

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView("Loading \(noun)...")
                    .containerRelativeFrame(.vertical)
            } else if let error = error {
                ContentUnavailableView(
                    LocalizedStringKey("Couldn't load \(noun)"),
                    systemImage: "exclamationmark.circle",
                    description: Text(error.localizedDescription)
                )
                .containerRelativeFrame(.vertical)
            } else if let data = data {
                content(data)
            } else {
                ContentUnavailableView(
                    LocalizedStringKey("No \(noun) data"),
                    systemImage: emptyIcon,
                    description: Text(LocalizedStringKey("Could not parse \(noun) details"))
                )
                .containerRelativeFrame(.vertical)
            }
        }
    }
}
