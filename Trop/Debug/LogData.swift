//
//  LogData.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

extension Log {
    static var db: AppLogger { make("DB", file: "data") }
    static var downloadManager: AppLogger { make("DownloadManager", file: "data") }
}
