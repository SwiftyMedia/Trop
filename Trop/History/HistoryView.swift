//
//  HistoryView.swift
//  Trop
//
//  Created by 686udjie on 13/07/2026.
//

import SwiftUI

struct HistoryScreenView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel = HistoryView()
    @State private var isSelecting = false
    @State private var selectedEvents: Set<Event> = []

    private var displayableSections: [(title: String, entries: [DatabaseService.HistoryEntry])] {
        viewModel.groupedEntries.filter { !$0.entries.isEmpty }
    }

    private var allEvents: [Event] {
        displayableSections.flatMap(\.entries).map(\.event)
    }

    private var allDisplayableSongs: [SongItem] {
        displayableSections.flatMap(\.entries).map { entry in
            if let entity = entry.song {
                return SongItem(entity: entity)
            } else {
                return SongItem(
                    videoId: entry.event.songId,
                    title: entry.event.songId,
                    artists: [],
                    album: nil,
                    albumId: nil,
                    duration: 0,
                    thumbnailUrl: ArtworkURLs.fallback(for: entry.event.songId),
                    isExplicit: false,
                    playlistId: nil
                )
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $viewModel.source) {
                ForEach(HistorySource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Group {
                if viewModel.isLoading {
                    LoadingStateView("Loading history...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.source == .local {
                    localHistoryContent
                } else {
                    remoteHistoryContent
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            toolbarContent
        }
        .navigationBarBackButtonHidden(isSelecting)
        .onChange(of: viewModel.source) { _, newSource in
            if isSelecting {
                isSelecting = false
                selectedEvents.removeAll()
            }
            if newSource == .remote {
                Task { await viewModel.loadRemote() }
            }
        }
        .task { await viewModel.load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.source == .local && !displayableSections.isEmpty {
            if isSelecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isSelecting = false
                        selectedEvents.removeAll()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedEvents.count == allEvents.count {
                        Button("Deselect All") { selectedEvents.removeAll() }
                    } else {
                        Button("Select All") { selectedEvents = Set(allEvents) }
                    }
                }
                if !selectedEvents.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) {
                            Task {
                                await viewModel.deleteEvents(Array(selectedEvents))
                                selectedEvents.removeAll()
                                isSelecting = false
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Select") { isSelecting = true }
                }
            }
        }
    }

    // MARK: - Local

    private var localHistoryContent: some View {
        Group {
            if displayableSections.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Songs you play will appear here.")
                )
            } else {
                localList
            }
        }
    }

    private var localList: some View {
        List {
            ForEach(displayableSections.indices, id: \.self) { sectionIndex in
                let section = displayableSections[sectionIndex]
                Section {
                    ForEach(section.entries, id: \.event) { entry in
                        localRow(entry)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(LocalizedStringKey(section.title))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerTracksScroll()
    }

    @ViewBuilder
    private func localRow(_ entry: DatabaseService.HistoryEntry) -> some View {
        let song: SongItem = {
            if let entity = entry.song {
                return SongItem(entity: entity)
            } else {
                return SongItem(
                    videoId: entry.event.songId,
                    title: entry.event.songId,
                    artists: [],
                    album: nil,
                    albumId: nil,
                    duration: 0,
                    thumbnailUrl: ArtworkURLs.fallback(for: entry.event.songId),
                    isExplicit: false,
                    playlistId: nil
                )
            }
        }()
        let allItems = allDisplayableSongs
        let isSelected = selectedEvents.contains(entry.event)
        HStack(spacing: 0) {
            if isSelecting {
                Button {
                    if isSelected {
                        selectedEvents.remove(entry.event)
                    } else {
                        selectedEvents.insert(entry.event)
                    }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? settings.accentColor : .secondary)
                        .padding(.leading, 16)
                        .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
            }
            SongRowView(song: song, onTap: {
                if isSelecting {
                    if isSelected {
                        selectedEvents.remove(entry.event)
                    } else {
                        selectedEvents.insert(entry.event)
                    }
                } else {
                    PlaybackQueue.play(song, in: allItems, log: Log.historyView, context: "History play")
                }
            })
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Task { await viewModel.deleteEvents([entry.event]) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Remote

    private var remoteHistoryContent: some View {
        Group {
            if viewModel.isRemoteLoading {
                LoadingStateView("Loading history...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.remoteError {
                ContentUnavailableView(
                    "Couldn't load history",
                    systemImage: "exclamationmark.circle",
                    description: Text(error.localizedDescription)
                )
            } else if viewModel.remoteSections.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sign in to see your YouTube Music history.")
                )
            } else {
                remoteList
            }
        }
    }

    private var remoteList: some View {
        List {
            ForEach(viewModel.remoteSections.indices, id: \.self) { sectionIndex in
                let section = viewModel.remoteSections[sectionIndex]
                Section {
                    ForEach(section.songs, id: \.videoId) { song in
                        SongRowView(song: song, onTap: {
                            PlaybackQueue.play(song, in: section.songs, log: Log.historyView, context: "History play")
                        })
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(LocalizedStringKey(section.title))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerTracksScroll()
    }

}
