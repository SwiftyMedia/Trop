//
//  LastFMAuthWebView.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import SwiftUI
import WebKit

struct LastFMAuthWebView: View {
    var onComplete: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var token: String?
    @State private var isLoadingToken = true
    @State private var isExchanging = false
    @State private var errorText: String?
    @State private var authUrl: String?
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                if let urlString = authUrl, !isLoadingToken {
                    WebViewContainer(
                        urlString: urlString,
                        isExchanging: $isExchanging,
                        errorText: $errorText,
                        onPageFinished: { Task { await tryAutoComplete() } },
                        onComplete: { success in
                            onComplete(success)
                            dismiss()
                        }
                    )
                    .ignoresSafeArea()
                } else if isLoadingToken {
                    ProgressView("Requesting Last.fm token…")
                } else if let err = errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text(err).multilineTextAlignment(.center).padding(.horizontal)
                        Button("Retry") { Task { await fetchToken() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }

                if isExchanging {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    ProgressView("Completing login…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Last.fm Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        pollingTask?.cancel()
                        pollingTask = nil
                        onComplete(false)
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                            Text("Close")
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    if let urlStr = authUrl, let host = URL(string: urlStr)?.host {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("last.fm").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )
            ) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .task { await fetchToken() }
            .onAppear {
                Log.lastfm.info("OAuth WebView loading host=\(authUrl.flatMap { URL(string: $0)?.host } ?? "last.fm")")
            }
            .onDisappear {
                pollingTask?.cancel()
                pollingTask = nil
            }
            .onChange(of: isLoadingToken) { _, loading in
                if !loading, token != nil {
                    startPolling()
                }
            }
        }
    }

    private func fetchToken() async {
        await MainActor.run {
            isLoadingToken = true
            errorText = nil
            token = nil
            authUrl = nil
        }
        do {
            let tok = try await LastFMService.shared.getToken()
            await MainActor.run {
                self.token = tok
                self.authUrl = LastFMDefaults.authUrl(token: tok)
                self.isLoadingToken = false
                Log.lastfm.info("LastFM auth token issued, loading approval page")
                startPolling()
            }
        } catch {
            await MainActor.run {
                isLoadingToken = false
                errorText = error.localizedDescription
            }
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        guard let tok = token else { return }
        pollingTask = Task {
            // Poll every 2s — Last.fm has no redirect, we detect when token becomes authorized
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                // Don't poll while already exchanging
                if await MainActor.run(body: { isExchanging }) { continue }
                do {
                    let auth = try await LastFMService.shared.getSession(token: tok)
                    LastFMTokenStore.shared.store(sessionKey: auth.session.key, username: auth.session.name)
                    await MainActor.run {
                        pollingTask?.cancel()
                        pollingTask = nil
                        isExchanging = false
                        onComplete(true)
                        dismiss()
                    }
                    break
                } catch let e as LastFMError {
                    if case .unauthorizedToken = e {
                        continue // not yet authorized — keep polling
                    }
                    // Other API errors are not retried silently
                    continue
                } catch {
                    continue
                }
            }
        }
    }

    private func tryAutoComplete() async {
        guard let tok = token, !isExchanging else { return }
        // Silent probe — don't show overlay unless success
        do {
            let auth = try await LastFMService.shared.getSession(token: tok)
            LastFMTokenStore.shared.store(sessionKey: auth.session.key, username: auth.session.name)
            await MainActor.run {
                pollingTask?.cancel()
                pollingTask = nil
                isExchanging = true // briefly show overlay before dismiss, like Discord
                onComplete(true)
                dismiss()
            }
        } catch let e as LastFMError {
            if case .unauthorizedToken = e { return }
            // ignore other errors until next poll
        } catch {
            return
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let urlString: String
    @Binding var isExchanging: Bool
    @Binding var errorText: String?
    var onPageFinished: (() -> Void)?
    var onComplete: (Bool) -> Void

    func makeUIView(context: UIViewRepresentableContext<WebViewContainer>) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Reuse Discord's Safari-like UA to avoid Last.fm blocking embedded agents
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        context.coordinator.webViewRef = webView
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: UIViewRepresentableContext<WebViewContainer>) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isExchanging: $isExchanging, errorText: $errorText, onPageFinished: onPageFinished, onComplete: onComplete)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isExchanging: Bool
        @Binding var errorText: String?
        var onComplete: (Bool) -> Void
        var onPageFinished: (() -> Void)?
        weak var webViewRef: WKWebView?

        init(isExchanging: Binding<Bool>, errorText: Binding<String?>, onPageFinished: (() -> Void)? = nil, onComplete: @escaping (Bool) -> Void) {
            self._isExchanging = isExchanging
            self._errorText = errorText
            self.onPageFinished = onPageFinished
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageFinished?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            errorText = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            errorText = error.localizedDescription
        }
    }
}
