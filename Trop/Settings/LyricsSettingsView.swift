//
//  LyricsSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct LyricsSettingsView: View {
    @Environment(\.settingsStore) private var settings

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                ForEach(LyricsProviderRegistry.all, id: \.id) { provider in
                    Toggle(isOn: Binding(
                        get: { !settings.disabledLyricsProviders.contains(provider.id) },
                        set: { enabled in
                            var disabled = settings.disabledLyricsProviders
                            if enabled {
                                disabled.remove(provider.id)
                            } else {
                                disabled.insert(provider.id)
                            }
                            settings.disabledLyricsProviders = disabled
                        }
                    )) {
                        Label(provider.name, systemImage: "music.note")
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Disabled providers are skipped when fetching lyrics.")
            }

            Section {
                NavigationLink {
                    LyricsProviderOrderView()
                } label: {
                    Label("Provider Order", systemImage: "list.number")
                }
            }

            Section {
                SettingsToggleRow("Word-by-Word Lyrics", icon: "textformat.abc", isOn: $settings.wordByWordLyrics)
            } header: {
                Text("Display")
            } footer: {
                Text("Highlights the current word during playback when timings are available. Falls back to line highlighting otherwise.")
            }
        }
        .navigationTitle("Lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
