//
//  SearchView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import SwiftUI

struct SearchView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel = SearchViewModel()
    @ObservedObject private var router = AppRouter.shared
    @FocusState private var fieldFocused: Bool

    @State private var pendingRoute: DetailRoute?

    var body: some View {
        NavigationStack(path: $router.searchPath) {
            VStack(spacing: 0) {
                searchTopBar

                content
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .onChange(of: pendingRoute) { _, route in
                if let route {
                    router.searchPath.append(route)
                    pendingRoute = nil
                }
            }
            .onAppear {
                viewModel.loadSearchHistory()
                focusIfSearchTab()
            }
            .onChange(of: router.selectedTabIndex) { _, _ in
                focusIfSearchTab()
            }
            .task(id: viewModel.results.count) {
                let urls = viewModel.results
                    .flatMap(\.items)
                    .compactMap(\.thumbnailUrl)
                    .compactMap(URL.init)
                await ImagePreloader.shared.preload(urls)
            }
        }
    }

    // MARK: - Top bar

    /// Search field + sort menu pinned above the filter chips.
    private var searchTopBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $viewModel.fieldText)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { submit(nil) }
                if !viewModel.fieldText.isEmpty {
                    Button {
                        viewModel.fieldText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color(.systemGray5).opacity(0.6))
            )

            sortMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SearchSort.allCases, id: \.self) { option in
                Button {
                    viewModel.sort = option
                } label: {
                    if viewModel.sort == option {
                        Label(LocalizedStringKey(option.title), systemImage: "checkmark")
                    } else {
                        Text(LocalizedStringKey(option.title))
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(.systemGray5).opacity(0.6)))
        }
        .accessibilityLabel("Sort results")
    }

    /// Focuses the field (raising the keyboard) whenever the Search tab
    /// becomes active.
    private func focusIfSearchTab() {
        if AppRouter.shared.selectedTabIndex == 3 {
            fieldFocused = true
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            if viewModel.searchHistory.isEmpty {
                noRecentSearchesView
            } else {
                searchHistoryView
            }
        case .loading:
            loadingView
        case .results:
            searchResultsList
        case .noResults:
            noResultsView
        case .failed:
            errorView(viewModel.error)
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ShimmerLoadingView()
            Spacer()
        }
    }

    // MARK: - Submission

    private func submit(_ text: String? = nil) {
        if let text {
            viewModel.fieldText = text
        }
        fieldFocused = false
        viewModel.submit()
    }

    private var searchHistoryView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recently searched")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Clear") {
                        viewModel.clearSearchHistory()
                    }
                    .font(.subheadline)
                    .foregroundColor(settings.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ForEach(viewModel.searchHistory, id: \.query) { entry in
                    Button {
                        submit(entry.query)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                .foregroundColor(settings.accentColor)
                            Text(entry.query)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteSearchHistoryEntry(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !viewModel.availableFilters.isEmpty {
                    filterChips
                }

                if let hero = viewModel.heroArtist {
                    artistHeroCard(hero, songs: viewModel.heroSongs)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                ForEach(viewModel.filteredResults) { section in
                    sectionHeader(section.title)

                    switch section.title {
                    case "Artists":
                        artistCarousel(items: section.items)
                    case "Albums":
                        albumCarousel(items: section.items)
                    default:
                        ForEach(section.items, id: \.id) { item in
                            YouTubeListItemView(item: item, onTap: {
                                handleItemTap(item)
                            }, onNavigate: { pendingRoute = $0 })
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
    }

    /// Section title with chevron — taps drill into (or clear) the filter.
    private func sectionHeader(_ title: String) -> some View {
        Button {
            if viewModel.selectedSectionFilter == title {
                viewModel.selectedSectionFilter = nil
            } else {
                viewModel.selectedSectionFilter = title
                viewModel.isShowingLibrary = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// Artist-first hero: big circular artwork + name, then top songs.
    private func artistHeroCard(_ artist: ArtistItem, songs: [SongItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                router.searchPath.append(DetailRoute.artist(browseId: artist.browseId))
            } label: {
                HStack(spacing: 12) {
                    AsyncImageView(url: artist.thumbnailUrl)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("•••")
                        .font(.body.weight(.black))
                        .foregroundStyle(settings.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(songs, id: \.videoId) { song in
                let item = YTItem.song(song)
                YouTubeListItemView(item: item, onTap: {
                    handleItemTap(item)
                }, onNavigate: { pendingRoute = $0 })
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }

    private func artistCarousel(items: [YTItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    if case .artist(let artist) = item {
                        Button {
                            router.searchPath.append(DetailRoute.artist(browseId: artist.browseId))
                        } label: {
                            VStack(spacing: 8) {
                                AsyncImageView(url: artist.thumbnailUrl)
                                    .frame(width: 110, height: 110)
                                    .clipShape(Circle())
                                Text(artist.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 110)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func albumCarousel(items: [YTItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items, id: \.id) { item in
                    if case .album(let album) = item {
                        Button {
                            router.searchPath.append(DetailRoute.album(browseId: album.browseId))
                        } label: {
                            MediaGridCell(
                                thumbnailUrl: album.thumbnailUrl,
                                title: album.title,
                                subtitle: album.artists.map(\.name).joined(separator: ", "),
                                size: 140
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var filterChips: some View {
        FilterChipBar(
            items: ["All Results"] + viewModel.availableFilters,
            id: \.self,
            title: { $0 },
            isSelected: { filter in
                if filter == "All Results" {
                    return viewModel.selectedSectionFilter == nil && !viewModel.isShowingLibrary
                }
                return filter == "Library"
                    ? viewModel.isShowingLibrary
                    : viewModel.selectedSectionFilter == filter
            },
            onTap: { filter in
                if filter == "All Results" {
                    viewModel.selectedSectionFilter = nil
                    viewModel.isShowingLibrary = false
                } else if filter == "Library" {
                    let willShow = !viewModel.isShowingLibrary
                    viewModel.isShowingLibrary = willShow
                    viewModel.selectedSectionFilter = nil
                } else {
                    viewModel.selectedSectionFilter = filter
                    viewModel.isShowingLibrary = false
                }
            }
        )
    }

    private var noResultsView: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No results found for \"\(viewModel.submittedQuery)\"")
        )
    }

    private var noRecentSearchesView: some View {
        ContentUnavailableView(
            "No Recent Searches",
            systemImage: "magnifyingglass",
            description: Text("Your recent searches will appear here.")
        )
    }

    private func errorView(_ error: Error?) -> some View {
        ContentUnavailableView(
            "Search failed",
            systemImage: "exclamationmark.triangle",
            description: Text(error?.localizedDescription ?? "Something went wrong.")
        )
    }

    private func handleItemTap(_ item: YTItem) {
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.searchView) },
            appendRoute: { router.searchPath.append($0) }
        )
    }
}
