//
//  DiscordAuth.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation

struct DiscordAuthResult {
    let accessToken: String
    let refreshToken: String
    let expiresInSec: Int64
    let scope: String
}

enum DiscordAuthError: Error, LocalizedError {
    case networkFailure(Error)
    case invalidGrant

    var errorDescription: String? {
        switch self {
        case .networkFailure(let e): return "Network failure: \(e.localizedDescription)"
        case .invalidGrant: return "Invalid grant"
        }
    }
}

final class DiscordAuth {
    func refresh(refreshToken: String) async throws -> DiscordAuthResult {
        try await performTokenExchange(grantType: "refresh_token", extra: ["refresh_token": refreshToken])
    }

    private func performTokenExchange(grantType: String, extra: [String: String]) async throws -> DiscordAuthResult {
        guard let url = URL(string: DiscordDefaults.oauthToken) else { throw DiscordAuthError.networkFailure(URLError(.badURL)) }
        var components = URLComponents()
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: DiscordDefaults.appId),
            URLQueryItem(name: "grant_type", value: grantType)
        ]
        if !DiscordDefaults.clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: DiscordDefaults.clientSecret))
        }
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        components.queryItems = items
        let bodyString = components.percentEncodedQuery ?? ""
        let loggedParameterNames = items.map(\.name).filter { $0 != "client_secret" }.sorted().joined(separator: ",")
        Log.discord.debug(
            "Token exchange grant=\(grantType) params=\(loggedParameterNames) "
                + "hasClientSecret=\(!DiscordDefaults.clientSecret.isEmpty)"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)
        request.timeoutInterval = 15

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await HttpClient.data(for: request)
        } catch {
            Log.discord.error("Token exchange grant=\(grantType) transport error: \(error.localizedDescription)")
            throw DiscordAuthError.networkFailure(error)
        }
        let status = httpResponse.statusCode
        let body = String(data: data, encoding: .utf8) ?? ""

        if (200...299).contains(status) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let accessToken = json["access_token"] as? String else {
                Log.discord.error("Token exchange grant=\(grantType) status=\(status) but no access_token in response")
                throw DiscordAuthError.networkFailure(NSError(domain: "DiscordAuth", code: status, userInfo: [NSLocalizedDescriptionKey: body]))
            }
            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn = (json["expires_in"] as? NSNumber)?.int64Value ?? Int64((json["expires_in"] as? Int ?? 0))
            let scope = json["scope"] as? String ?? ""
            Log.discord.info("Token exchange ok grant=\(grantType) status=\(status) scope=\(scope) expiresIn=\(expiresIn)s")
            Log.discord.debug("Token exchange hasRefresh=\(!refreshToken.isEmpty)")
            return DiscordAuthResult(accessToken: accessToken, refreshToken: refreshToken, expiresInSec: expiresIn, scope: scope)
        }

        var errorCode = ""
        var errorDesc = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            errorCode = json["error"] as? String ?? ""
            errorDesc = json["error_description"] as? String ?? ""
        }
        Log.discord.error("Token exchange failed grant=\(grantType) status=\(status) error=\(errorCode) desc=\(errorDesc)")
        if status == 400 || status == 401,
           ["invalid_grant", "invalid_client", "invalid_request", "unauthorized_client"].contains(errorCode) {
            throw DiscordAuthError.invalidGrant
        }
        throw DiscordAuthError.networkFailure(
            NSError(domain: "DiscordAuth", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(body)"])
        )
    }
}
