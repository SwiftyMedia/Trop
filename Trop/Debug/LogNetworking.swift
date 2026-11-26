//
//  LogNetworking.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

extension Log {
    static var innerTube: AppLogger { make("InnerTube", file: "networking") }
    static var parser: AppLogger { make("Parser", file: "networking") }
    static var search: AppLogger { make("Search", file: "networking") }
    static var searchView: AppLogger { make("SearchView", file: "networking") }
    static var explore: AppLogger { make("Explore", file: "networking") }
}
