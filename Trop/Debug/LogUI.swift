//
//  LogUI.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

extension Log {
    static var albumDetail: AppLogger { make("AlbumDetail", file: "ui") }
    static var albumDetailViewModel: AppLogger { make("AlbumDetailViewModel", file: "ui") }
    static var artistDetail: AppLogger { make("ArtistDetail", file: "ui") }
    static var podcastDetail: AppLogger { make("PodcastDetail", file: "ui") }
    static var historyView: AppLogger { make("HistoryView", file: "ui") }
    static var homeScreenView: AppLogger { make("HomeScreenView", file: "ui") }
    static var homeViewModel: AppLogger { make("HomeViewModel", file: "ui") }
    static var libraryView: AppLogger { make("LibraryView", file: "ui") }
    static var settings: AppLogger { make("Settings", file: "ui") }
}
