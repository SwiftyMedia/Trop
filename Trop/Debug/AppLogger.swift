//
//  AppLogger.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

import OSLog

struct AppLogger {
    let logger: Logger
    let category: String
    var writesToDisk = true
    var redact = true

    private func emit(_ level: String, _ message: String) {
        guard writesToDisk else { return }
        DebugLogStore.shared.append(category: category, level: level, message: message)
    }

    func debug(_ message: String) {
        emit("DEBUG", message)
        if redact { logger.debug("\(message, privacy: .private)") } else { logger.debug("\(message)") }
    }

    func info(_ message: String) {
        emit("INFO", message)
        if redact { logger.info("\(message, privacy: .private)") } else { logger.info("\(message)") }
    }

    func notice(_ message: String) {
        emit("NOTICE", message)
        if redact { logger.notice("\(message, privacy: .private)") } else { logger.notice("\(message)") }
    }

    func warning(_ message: String) {
        emit("WARNING", message)
        if redact { logger.warning("\(message, privacy: .private)") } else { logger.warning("\(message)") }
    }

    func error(_ message: String) {
        emit("ERROR", message)
        if redact { logger.error("\(message, privacy: .private)") } else { logger.error("\(message)") }
    }

    func fault(_ message: String) {
        emit("FAULT", message)
        if redact { logger.fault("\(message, privacy: .private)") } else { logger.fault("\(message)") }
    }
}
