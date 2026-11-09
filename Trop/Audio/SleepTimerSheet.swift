//
//  SleepTimerSheet.swift
//  Trop
//
//  Preset / end-of-track / custom picker for the sleep timer.
//

import SwiftUI

struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var timer = SleepTimerController.shared

    @State private var showCustomPrompt = false
    @State private var customMinutesText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    presetRow(
                        title: NSLocalizedString("Off", comment: "Sleep timer off"),
                        selected: !timer.isActive
                    ) {
                        timer.turnOff()
                        dismiss()
                    }

                    ForEach(SleepTimerController.presetMinutes, id: \.self) { minutes in
                        presetRow(
                            title: SleepTimerController.minutesLabel(minutes),
                            selected: isSelectedDuration(minutes)
                        ) {
                            timer.start(minutes: minutes)
                            dismiss()
                        }
                    }

                    presetRow(
                        title: NSLocalizedString("End of Track", comment: "Sleep timer end of track"),
                        selected: timer.stopsAtEndOfTrack
                    ) {
                        timer.startEndOfTrack()
                        dismiss()
                    }

                    Button {
                        customMinutesText = ""
                        showCustomPrompt = true
                    } label: {
                        HStack {
                            Text(LocalizedStringKey("Custom…"))
                            Spacer()
                        }
                    }
                } footer: {
                    if timer.isActive {
                        Text(timer.statusText)
                    }
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .textPrompt(
                "Custom…",
                isPresented: $showCustomPrompt,
                placeholder: "Minutes",
                text: $customMinutesText,
                okTitle: "OK",
                message: Text(LocalizedStringKey("Enter minutes (1–180)"))
            ) {
                applyCustomMinutes()
            }
        }
        .appSheetChrome([.medium])
    }

    private func isSelectedDuration(_ minutes: Int) -> Bool {
        if case .duration(let value) = timer.mode {
            return value == minutes
        }
        return false
    }

    private func presetRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func applyCustomMinutes() {
        let trimmed = customMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(trimmed),
              SleepTimerController.customMinutesRange.contains(minutes) else { return }
        timer.start(minutes: minutes)
        dismiss()
    }
}
