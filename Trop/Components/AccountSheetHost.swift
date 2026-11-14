//
//  AccountSheetHost.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Shared account/session state for the app. Used by the tab headers
/// (avatar) and the account section at the top of Settings.
@MainActor
@Observable
final class AccountSheetState {
    static let shared = AccountSheetState()

    var accountName = "Guest"
    var accountImageUrl: String?
    /// Viewer's own channel id — set once account info is fetched, so the
    /// comments composer can link the photo to the viewer's artist page.
    var accountChannelId: String?
    var isLoginSheetPresented = false
    let loginModel = LoginViewModel()

    private let cookieStore = CookieStore()
    private var hasAttemptedTokenRefresh = false
    private var isFetchingAccountInfo = false
    private var accountInfoFetchID: UUID?
    private var accountInfoGeneration = 0

    var isLoggedIn: Bool { loginModel.isLoggedIn }

    private init() {}

    func restoreSession() async {
        hasAttemptedTokenRefresh = false
        await loginModel.restoreSessionIfPresent()
    }

    func fetchAccountInfo() async {
        guard loginModel.isLoggedIn, !isFetchingAccountInfo else { return }
        let generation = accountInfoGeneration
        let fetchID = UUID()
        isFetchingAccountInfo = true
        accountInfoFetchID = fetchID
        defer {
            if accountInfoFetchID == fetchID {
                accountInfoFetchID = nil
                isFetchingAccountInfo = false
            }
        }
        for attempt in 1...3 {
            guard generation == accountInfoGeneration, loginModel.isLoggedIn else { return }
            let info: AccountInfo
            do {
                info = try await InnerTubeClient.tropShared.accountInfo()
            } catch {
                Log.loginViewModel.error("fetchAccountInfo: attempt \(attempt) failed: \(error)")
                return
            }
            guard generation == accountInfoGeneration, loginModel.isLoggedIn else { return }
            let knownName = !info.name.isEmpty && info.name != "Guest"
            guard knownName else {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                Log.loginViewModel.notice("fetchAccountInfo: giving up — menu stayed guest-shaped")
                if !hasAttemptedTokenRefresh {
                    hasAttemptedTokenRefresh = true
                    // Release the in-flight guard so refreshRotatedSession's
                    // own accountInfo fetch can run after the cookie reissue.
                    if accountInfoFetchID == fetchID {
                        accountInfoFetchID = nil
                        isFetchingAccountInfo = false
                    }
                    await refreshRotatedSession()
                }
                return
            }
            accountName = info.name
            if let channelId = info.channelId {
                accountChannelId = channelId
                Log.loginViewModel.debug("fetchAccountInfo: channelId=\(channelId)")
            }
            if let url = info.thumbnailUrl {
                accountImageUrl = url
                return
            }
            if accountImageUrl != nil || attempt == 3 {
                Log.loginViewModel.debug("fetchAccountInfo: name OK, no photo in response")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func handleLoginChange(_ loggedIn: Bool) {
        if loggedIn {
            isLoginSheetPresented = false
            hasAttemptedTokenRefresh = false
            Task { await fetchAccountInfo() }
        }
    }

    func signOut() {
        accountInfoGeneration &+= 1
        accountInfoFetchID = nil
        isFetchingAccountInfo = false
        loginModel.logout()
        accountName = "Guest"
        accountImageUrl = nil
        accountChannelId = nil
        hasAttemptedTokenRefresh = false
    }
    func refreshRotatedSession() async {
        let base = await cookieStore.cookies()
        let sapisid = await cookieStore.sapisid()
        guard sapisid != nil else { return }
        let refreshed = await SessionTokenRefresher.shared.refreshRotatedTokens(baseCookies: base)
        guard !refreshed.isEmpty else { return }
        await cookieStore.save(
            cookies: refreshed,
            sapisid: sapisid,
            visitorData: refreshed["visitor_data"],
            dataSyncId: await cookieStore.dataSyncId()
        )
        Log.loginViewModel.notice("refreshRotatedSession: reissued cookies persisted — reloading state")
        await InnerTubeClient.tropShared.loadState(from: cookieStore)
        await fetchAccountInfo()
    }
}

struct LoginSheetHost: ViewModifier {
    @Bindable var state: AccountSheetState
    @ObservedObject private var loginModel = AccountSheetState.shared.loginModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.isLoginSheetPresented) {
                NavigationStack {
                    LoginWebView(model: state.loginModel)
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { state.isLoginSheetPresented = false }
                            }
                        }
                }
            }
            .onChange(of: loginModel.isLoggedIn) { _, loggedIn in
                if loggedIn {
                    state.isLoginSheetPresented = false
                    Task { await state.fetchAccountInfo() }
                }
            }
    }
}

extension View {
    func loginSheet(state: AccountSheetState) -> some View {
        modifier(LoginSheetHost(state: state))
    }
}
