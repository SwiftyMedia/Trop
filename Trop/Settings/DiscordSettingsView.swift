//
//  DiscordSettingsView.swift
//  Trop
//

import SwiftUI
import Combine

struct DiscordSettingsView: View {
    @State private var status: DiscordRpcManager.Status = .disconnected
    @State private var lastError: String?
    @State private var currentUser: DiscordUser?
    @State private var isBusy = false

    @AppStorage("discordRPCEnable") private var discordEnabled = true
    @AppStorage("discordInfoDismissed") private var infoDismissed = false
    @AppStorage("discordAdvancedMode") private var advancedMode = false
    @AppStorage("discordActivityType") private var activityType = DiscordDefaults.activityType
    @AppStorage("discordStateTemplate") private var stateTemplate = DiscordDefaults.stateTemplate
    @AppStorage("discordDetailsTemplate") private var detailsTemplate = DiscordDefaults.detailsTemplate
    @AppStorage("discordButton1Enabled") private var btn1Enabled = true
    @AppStorage("discordButton1Label") private var btn1Label = DiscordDefaults.button1Label
    @AppStorage("discordButton1Url") private var btn1Url = DiscordDefaults.button1UrlTemplate
    @AppStorage("discordButton2Enabled") private var btn2Enabled = true
    @AppStorage("discordButton2Label") private var btn2Label = DiscordDefaults.button2Label
    @AppStorage("discordButton2Url") private var btn2Url = DiscordDefaults.button2Url
    @AppStorage("discordActivityName") private var activityName = DiscordDefaults.activityName
    @AppStorage("discordUserStatus") private var userStatus = DiscordDefaults.userStatus

    @State private var showStateTemplateEditor = false
    @State private var showDetailsTemplateEditor = false
    @State private var showActivityNameEditor = false
    @State private var showBtn1LabelEditor = false
    @State private var showBtn1UrlEditor = false
    @State private var showBtn2LabelEditor = false
    @State private var showBtn2UrlEditor = false

    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        List {
            if !infoDismissed {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Discord Rich Presence uses Discord's Social SDK. Token stays encrypted in Keychain.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Button("Dismiss") { infoDismissed = true }
                            .font(.footnote)
                    }
                }
            }

            // Login / Profile — top cell handles both states
            Section("Account") {
                if let user = currentUser {
                    HStack(spacing: 14) {
                        CachedAvatarView(url: avatarURL(for: user), size: 56)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name).font(.headline)
                            Text("@\(user.username)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Logout", role: .destructive) {
                            DiscordRpcManager.shared.logout()
                            currentUser = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                    .padding(.vertical, 4)

                    if let err = lastError {
                        Text(mapError(err)).font(.footnote).foregroundStyle(.red)
                    }
                } else {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not logged in").font(.headline)
                            Text("Connect to show listening activity").font(.caption).foregroundStyle(.secondary)
                            if let err = lastError {
                                Text(mapError(err)).font(.caption2).foregroundStyle(.red).lineLimit(2)
                            } else if isBusy {
                                Text("Authorizing…").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if isBusy {
                            ProgressView()
                        } else {
                            Button("Login") {
                                isBusy = true
                                DiscordRpcManager.shared.authorize { success in
                                    isBusy = false
                                    if success {
                                        Task { await refreshUser() }
                                    }
                                }
                            }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Options shown always — login gates RPC but not configuration
            Section("Options") {
                Toggle("Enable Discord RPC", isOn: $discordEnabled)
                Toggle("Advanced Mode", isOn: $advancedMode)
                    .onChange(of: advancedMode) { _, _ in
                        DiscordRpcManager.shared.notifySettingsChanged()
                    }
            }

            if advancedMode {
                    Section("Presence") {
                        Picker("Activity Type", selection: $activityType) {
                            Text("Playing").tag("0")
                            Text("Listening").tag("2")
                            Text("Watching").tag("3")
                            Text("Competing").tag("5")
                        }
                        .onChange(of: activityType) { _, _ in
                            DiscordRpcManager.shared.notifySettingsChanged()
                        }

                        // swiftlint:disable:next multiple_closures_with_trailing_closure
                        Button(action: { showActivityNameEditor = true }) {
                            HStack {
                                Text("Activity Name")
                                Spacer()
                                Text(displayActivityName).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        // swiftlint:disable:next multiple_closures_with_trailing_closure
                        Button(action: { showStateTemplateEditor = true }) {
                            HStack {
                                Text("State Template")
                                Spacer()
                                Text(stateTemplate).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        // swiftlint:disable:next multiple_closures_with_trailing_closure
                        Button(action: { showDetailsTemplateEditor = true }) {
                            HStack {
                                Text("Details Template")
                                Spacer()
                                Text(detailsTemplate).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }

                    Section("Buttons") {
                        Toggle("Button 1", isOn: $btn1Enabled)
                        if btn1Enabled {
                            // swiftlint:disable:next multiple_closures_with_trailing_closure
                            Button(action: { showBtn1LabelEditor = true }) {
                                HStack {
                                    Text("Label")
                                    Spacer()
                                    Text(btn1Label).foregroundStyle(.secondary)
                                }
                            }
                            // swiftlint:disable:next multiple_closures_with_trailing_closure
                            Button(action: { showBtn1UrlEditor = true }) {
                                HStack {
                                    Text("URL")
                                    Spacer()
                                    Text(btn1Url).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        Toggle("Button 2", isOn: $btn2Enabled)
                        if btn2Enabled {
                            // swiftlint:disable:next multiple_closures_with_trailing_closure
                            Button(action: { showBtn2LabelEditor = true }) {
                                HStack {
                                    Text("Label")
                                    Spacer()
                                    Text(btn2Label).foregroundStyle(.secondary)
                                }
                            }
                            // swiftlint:disable:next multiple_closures_with_trailing_closure
                            Button(action: { showBtn2UrlEditor = true }) {
                                HStack {
                                    Text("URL")
                                    Spacer()
                                    Text(btn2Url).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }

                    Section("Status") {
                        Picker("User Status", selection: $userStatus) {
                            Text("Online").tag("online")
                            Text("Idle").tag("idle")
                            Text("DND").tag("dnd")
                        }
                    }
                }

                Section("Preview") {
                    RichPresencePreview()
                }
        }
        .navigationTitle("Discord")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bind() }
        .task { await refreshUserIfNeeded() }
        .textPrompt("Activity Name", isPresented: $showActivityNameEditor, placeholder: "Activity Name", text: $activityName) {
            DiscordRpcManager.shared.notifySettingsChanged()
        }
        .textPrompt("State Template", isPresented: $showStateTemplateEditor, placeholder: "Template", text: $stateTemplate) {
            DiscordRpcManager.shared.notifySettingsChanged()
        }
        .textPrompt("Details Template", isPresented: $showDetailsTemplateEditor, placeholder: "Template", text: $detailsTemplate) {
            DiscordRpcManager.shared.notifySettingsChanged()
        }
        .textPrompt("Button 1 Label", isPresented: $showBtn1LabelEditor, placeholder: "Label", text: $btn1Label)
        .textPrompt("Button 1 URL", isPresented: $showBtn1UrlEditor, placeholder: "URL", text: $btn1Url)
        .textPrompt("Button 2 Label", isPresented: $showBtn2LabelEditor, placeholder: "Label", text: $btn2Label)
        .textPrompt("Button 2 URL", isPresented: $showBtn2UrlEditor, placeholder: "URL", text: $btn2Url)
    }

    private var displayActivityName: String {
        activityName.isEmpty ? DiscordDefaults.unknownArtist : activityName
    }

    private var isLoggedIn: Bool { DiscordRpcManager.shared.getAccessToken() != nil }

    private func avatarURL(for user: DiscordUser) -> URL? {
        guard let str = user.avatar else { return nil }
        return URL(string: str)
    }

    private func bind() {
        DiscordRpcManager.shared.connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { s in status = s }
            .store(in: &cancellables)
        DiscordRpcManager.shared.lastError
            .receive(on: DispatchQueue.main)
            .sink { e in lastError = e }
            .store(in: &cancellables)
        DiscordRpcManager.shared.currentUser
            .receive(on: DispatchQueue.main)
            .sink { u in currentUser = u }
            .store(in: &cancellables)
        status = DiscordRpcManager.shared.connectionStatusValue
        lastError = DiscordRpcManager.shared.lastErrorValue
        currentUser = DiscordRpcManager.shared.currentUserValue
    }

    private func refreshUserIfNeeded() async {
        if currentUser == nil, let token = DiscordRpcManager.shared.getAccessToken() {
            await refreshUser(with: token)
        }
    }

    private func refreshUser() async {
        guard let token = DiscordRpcManager.shared.getAccessToken() else { return }
        await refreshUser(with: token)
    }

    private func refreshUser(with token: String) async {
        if let user = await DiscordRpcManager.shared.fetchCurrentUserAsync2(token: token) {
            await MainActor.run { currentUser = user }
        }
    }

    private func mapError(_ key: String) -> String {
        switch key {
        case "discord_error_token_refresh_failed": return "Token refresh failed — please login again."
        case "discord_error_invalid_scope": return "Invalid scope or state mismatch."
        case "discord_error_no_browser": return "No browser available."
        default: return "Connection error. Please try again."
        }
    }
}

private struct RichPresencePreview: View {
    @AppStorage("discordStateTemplate") private var stateTemplate = DiscordDefaults.stateTemplate
    @AppStorage("discordDetailsTemplate") private var detailsTemplate = DiscordDefaults.detailsTemplate
    @AppStorage("discordAdvancedMode") private var advancedMode = false
    @AppStorage("discordActivityType") private var activityType = DiscordDefaults.activityType
    @AppStorage("discordActivityName") private var activityName = DiscordDefaults.activityName
    @AppStorage("discordButton1Enabled") private var btn1Enabled = true
    @AppStorage("discordButton1Label") private var btn1Label = DiscordDefaults.button1Label
    @AppStorage("discordButton2Enabled") private var btn2Enabled = true
    @AppStorage("discordButton2Label") private var btn2Label = DiscordDefaults.button2Label

    // Pull live NowPlaying if available, fallback to mock
    // swiftlint:disable:next large_tuple
    private var live: (title: String, artist: String, album: String?, songId: String, thumb: String?) {
        if let vid = NowPlaying.shared.videoId,
           let song = NowPlaying.shared.queueSongs.first(where: { $0.videoId == vid }) {
            let artist = song.artists.map(\.name).joined(separator: ", ")
            return (song.title, artist.isEmpty ? DiscordDefaults.unknownArtist : artist, song.album, song.videoId, song.thumbnailUrl)
        }
        if let vid = NowPlaying.shared.videoId {
            return (NowPlaying.shared.title.isEmpty ? "Song Title" : NowPlaying.shared.title,
                    NowPlaying.shared.displayArtist.isEmpty ? "Artist Name" : NowPlaying.shared.displayArtist,
                    NowPlaying.shared.albumTitle.isEmpty ? "Album" : NowPlaying.shared.albumTitle,
                    vid, nil)
        }
        return ("Song Title", "Artist Name", "Album", "xxxx", nil)
    }

    // swiftlint:disable:next large_tuple
    private var rendered: (name: String, details: String, state: String) {
        let l = live
        if advancedMode {
            // swiftlint:disable:next line_length
            let name = activityName.isEmpty ? l.artist : DiscordTemplateRenderer.render(template: activityName, title: l.title, artist: l.artist, album: l.album, songId: l.songId)
            // swiftlint:disable:next line_length
            let details = DiscordTemplateRenderer.render(template: detailsTemplate.isEmpty ? DiscordDefaults.detailsTemplate : detailsTemplate, title: l.title, artist: l.artist, album: l.album, songId: l.songId)
            // swiftlint:disable:next line_length
            let state = DiscordTemplateRenderer.render(template: stateTemplate.isEmpty ? DiscordDefaults.stateTemplate : stateTemplate, title: l.title, artist: l.artist, album: l.album, songId: l.songId)
            return (name, details, state)
        } else {
            return (l.artist, l.title, l.artist)
        }
    }

    private func fmt(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        let l = live
        let r = rendered
        // Progress uses live NowPlaying if playing, else mock 5 / 175 as in screenshot
        let cur = NowPlaying.shared.isPlaying ? Int(NowPlaying.shared.currentTime) : 5
        let dur = NowPlaying.shared.duration > 0 ? Int(NowPlaying.shared.duration) : (l.songId == "xxxx" ? 175 : Int(NowPlaying.shared.duration))
        let displayDur = dur > 0 ? dur : 175
        let progress = displayDur > 0 ? CGFloat(cur) / CGFloat(displayDur) : 0.03
        // Header: "Listening to {artist}" — Discord shows activity name artist
        let header = "Listening to \(l.artist)"
        VStack(alignment: .leading, spacing: 12) {
            Text(header).font(.subheadline).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: l.thumb.flatMap(URL.init)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .failure: ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)) }
                    case .empty: ZStack { Color.white.opacity(0.08); ProgressView().tint(.white) }
                    @unknown default: Color.white.opacity(0.08)
                    }
                }
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.details).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(r.state).font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    // Album line — from rendered statedetails split? Use live album mocked as "Close Within"
                    Text(l.album ?? "Close Within").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18)).frame(height: 5)
                        Capsule().fill(Color.white).frame(width: geo.size.width * min(max(progress, 0), 1), height: 5)
                            .overlay(Circle().fill(Color.white).frame(width: 9, height: 9), alignment: .trailing)
                    }
                }
                .frame(height: 5)
                HStack {
                    Text(fmt(min(cur, displayDur))).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(fmt(displayDur)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.top, 2)
            VStack(spacing: 10) {
                if btn1Enabled {
                    Text(btn1Label.isEmpty ? DiscordDefaults.button1Label : btn1Label)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.14)))
                }
                if btn2Enabled {
                    Text(btn2Label.isEmpty ? DiscordDefaults.button2Label : btn2Label)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.14)))
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.17, green: 0.17, blue: 0.18)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
