//
//  SleepTimerController.swift
//  Trop
//
//  Stops playback after a chosen duration or at the end of the current track,
//  with a short volume fade so the stop is not abrupt.
//

import Combine
import Foundation
import Observation

@Observable
@MainActor
final class SleepTimerController {
    static let shared = SleepTimerController()

    enum Mode: Equatable {
        case off
        case duration(minutes: Int)
        case endOfTrack
    }

    static let presetMinutes = [5, 10, 15, 30, 45, 60]
    static let fadeDuration: TimeInterval = 15
    static let customMinutesRange = 1...180

    private(set) var mode: Mode = .off
    private(set) var firesAt: Date?
    private(set) var remainingSeconds: TimeInterval = 0
    private(set) var isFading = false

    var isActive: Bool { mode != .off }

    /// True while end-of-track mode is armed (before it fires).
    var stopsAtEndOfTrack: Bool {
        if case .endOfTrack = mode { return true }
        return false
    }

    /// Subtitle for menu rows / indicators.
    var statusText: String {
        switch mode {
        case .off:
            return NSLocalizedString("Off", comment: "Sleep timer off")
        case .endOfTrack:
            return NSLocalizedString("End of Track", comment: "Sleep timer end of track")
        case .duration:
            if isFading {
                return NSLocalizedString("Stopping…", comment: "Sleep timer fading out")
            }
            return Self.formatRemaining(remainingSeconds)
        }
    }

    private var fireTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var isPerformingSleepStop = false

    private init() {}

    // MARK: - Public API

    func turnOff() {
        cancelFade(restoreVolume: isFading)
        clear()
    }

    func start(minutes: Int) {
        let clamped = min(max(minutes, Self.customMinutesRange.lowerBound), Self.customMinutesRange.upperBound)
        cancelFade(restoreVolume: isFading)
        clearTasks()
        mode = .duration(minutes: clamped)
        let deadline = Date().addingTimeInterval(TimeInterval(clamped * 60))
        firesAt = deadline
        remainingSeconds = deadline.timeIntervalSinceNow
        scheduleFire(at: deadline)
        Log.player.info("Sleep timer set for \(clamped) minutes")
    }

    func startEndOfTrack() {
        cancelFade(restoreVolume: isFading)
        clearTasks()
        mode = .endOfTrack
        firesAt = nil
        remainingSeconds = 0
        Log.player.info("Sleep timer set to end of track")
    }

    /// Called from `NowPlaying.stopped` on natural EOF. Returns `true` when
    /// auto-advance / repeat should be suppressed and playback left stopped.
    func handleTrackEnded() -> Bool {
        if isFading {
            finishStop(restoreVolume: true)
            return true
        }
        guard case .endOfTrack = mode else { return false }
        Log.player.info("Sleep timer stopped at end of track")
        finishStop(restoreVolume: true)
        return true
    }

    /// Aborts an in-progress fade when the user seeks, toggles playback, or
    /// changes volume. The timer is cleared because it already fired.
    func noteUserInteraction() {
        guard isFading, !isPerformingSleepStop else { return }
        Log.player.info("Sleep timer fade cancelled by user interaction")
        cancelFade(restoreVolume: true)
        clear()
    }

    // MARK: - Internals

    private func scheduleFire(at date: Date) {
        fireTask?.cancel()
        fireTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = date.timeIntervalSinceNow
                self.remainingSeconds = max(0, remaining)
                if remaining <= 0 {
                    self.fireTimed()
                    return
                }
                let chunk = min(1.0, remaining)
                try? await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000))
            }
        }
    }

    private func fireTimed() {
        guard case .duration = mode, !isFading else { return }
        fireTask?.cancel()
        fireTask = nil
        firesAt = nil
        remainingSeconds = 0
        // Already paused: just clear the timer without a fade.
        if PlayerController.shared.playState.value != .playing {
            Log.player.info("Sleep timer fired while paused — clearing")
            clear()
            return
        }
        Log.player.info("Sleep timer fired — fading out")
        startFadeThenPause()
    }

    private func startFadeThenPause() {
        fadeTask?.cancel()
        isFading = true
        let startVolume = SettingsStore.shared.playerVolume
        let duration = Self.fadeDuration

        fadeTask = Task { @MainActor [weak self] in
            let steps = 30
            let stepDuration = duration / Double(steps)
            for step in 1...steps {
                guard let self, !Task.isCancelled, self.isFading else { return }
                let progress = Double(step) / Double(steps)
                let volume = startVolume * (1 - progress)
                PlayerController.shared.setOutputVolume(volume)
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.isFading else { return }
            self.finishStop(restoreVolume: true)
        }
    }

    private func finishStop(restoreVolume: Bool) {
        isPerformingSleepStop = true
        defer { isPerformingSleepStop = false }

        fadeTask?.cancel()
        fadeTask = nil
        isFading = false

        PlayerController.shared.setPaused(true)
        if restoreVolume {
            PlayerController.shared.applyPlayerVolume()
        }
        clear()
    }

    private func cancelFade(restoreVolume: Bool) {
        fadeTask?.cancel()
        fadeTask = nil
        guard isFading else { return }
        isFading = false
        if restoreVolume {
            PlayerController.shared.applyPlayerVolume()
        }
    }

    private func clearTasks() {
        fireTask?.cancel()
        fireTask = nil
        fadeTask?.cancel()
        fadeTask = nil
    }

    private func clear() {
        clearTasks()
        mode = .off
        firesAt = nil
        remainingSeconds = 0
        isFading = false
    }

    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func minutesLabel(_ minutes: Int) -> String {
        String(format: NSLocalizedString("%d minutes", comment: "Sleep timer duration preset"), minutes)
    }
}
