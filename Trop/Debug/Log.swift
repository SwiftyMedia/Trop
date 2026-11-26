//
//  Log.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

import OSLog

enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.686udjie.Trop"

    static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static func make(
        _ category: String,
        file: String,
        writesToDisk: Bool = true,
        redact: Bool = true
    ) -> AppLogger {
        AppLogger(
            logger: logger(category: category),
            category: file,
            writesToDisk: writesToDisk,
            redact: redact
        )
    }

    static func wireSwiftyTube() {
        guard SwiftyTubeLog.handler == nil else { return }
        SwiftyTubeLog.handler = { message, level in
            let log = Log.make("SwiftyTube", file: "swiftytube")
            switch level {
            case .debug:
                log.debug(message)
            case .info:
                log.info(message)
            case .notice:
                log.notice(message)
            case .error:
                log.error(message)
            }
        }
    }
}
