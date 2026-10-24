//
//  RadioViews.swift
//  Trop
//
//  Created by 686udjie on 26/09/2026.
//

import SwiftUI

/// Style + size + explicit filter for song radio, applied client-side over
/// the single YTM `RDAMVM` mix.
struct RadioOptionsSheet: View {
    let song: SongItem
    @Environment(\.dismiss) private var dismiss
    @State private var options = RadioOptions.default
    @State private var isStarting = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Style", selection: $options.style) {
                        ForEach(RadioStyle.allCases) { style in
                            Text(LocalizedStringKey(style.displayName)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(LocalizedStringKey(options.style.description))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Sound")
                }

                Section {
                    Stepper(value: $options.limit, in: 5...50, step: 5) {
                        HStack {
                            Text(LocalizedStringKey("Tracks"))
                            Spacer()
                            Text("\(options.limit)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Include explicit", isOn: $options.allowExplicit)
                } header: {
                    Text("Queue")
                }

                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            Spacer()
                            if isStarting {
                                ProgressView()
                            } else {
                                Text(LocalizedStringKey("Start Radio"))
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isStarting)
                }
            }
            .navigationTitle("Customize Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .appSheetChrome()
        .onAppear { options = .saved }
    }

    private func start() {
        isStarting = true
        options.save()
        PlaybackQueue.startRadio(for: song, options: options)
        dismiss()
    }
}

/// "Similar to X" list built from the radio mix minus the seed.
struct SimilarSongsView: View {
    let song: SongItem
    var onNavigate: ((DetailRoute) -> Void)?
    var onPlaySong: ((SongItem, [SongItem]) -> Void)?

    @State private var songs: [SongItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                                Text(LocalizedStringKey("Finding similar tracks…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                ContentUnavailableView(
                    "No similar tracks",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(LocalizedStringKey("Try again later."))
                )
            } else {
                List {
                    ForEach(songs, id: \.videoId) { similar in
                        SongRowView(
                            song: similar,
                            onTap: {
                                if let onPlaySong {
                                    onPlaySong(similar, songs)
                                } else {
                                    PlaybackQueue.play(similar, in: songs, log: Log.search, context: "SimilarTo tap")
                                }
                            },
                            onNavigate: onNavigate
                        )
                        .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 8))
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(
            String(format: NSLocalizedString("Similar to %@", comment: "Similar song page title"), song.title)
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let radio = try? await PersonalizationService.shared.fetchRadio(
            videoId: song.videoId,
            options: RadioOptions(style: .similar, limit: 25, allowExplicit: true)
        ) else { return }
        songs = radio.songs.filter { $0.videoId != song.videoId }
    }
}
