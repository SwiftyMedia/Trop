//
//  LoggedTask.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

import Foundation

/// Runs an async operation and records failures through a category logger
@MainActor
func loggedTask(
    _ logger: AppLogger,
    _ message: String,
    operation: @escaping @MainActor @Sendable () async throws -> Void
) {
    Task { @MainActor in
        do {
            try await operation()
        } catch {
            logger.error("\(message): \(error)")
        }
    }
}
