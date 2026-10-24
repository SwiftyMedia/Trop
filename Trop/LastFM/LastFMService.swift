//
//  LastFMService.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation
import CryptoKit

struct LastFMSession: Decodable {
    let name: String
    let key: String
}

struct LastFMAuthResponse: Decodable {
    let session: LastFMSession
}

struct LastFMTokenResponse: Decodable {
    let token: String
}

struct LastFMErrorResponse: Decodable {
    let error: Int
    let message: String
}

private struct EmptyResponse: Decodable {}

enum LastFMError: Error, LocalizedError {
    case notConfigured
    case network(Error)
    case http(Int, String)
    case api(Int, String)
    case missingSession
    case unauthorizedToken
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Last.fm API keys not configured"
        case .network(let e): return e.localizedDescription
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .api(let code, let msg): return "Last.fm error \(code): \(msg)"
        case .missingSession: return "Missing session key"
        case .unauthorizedToken: return "Token not yet authorized — please approve on Last.fm and tap Done"
        case .invalidResponse: return "Invalid response"
        }
    }
}

/// Handles signing and network calls to Last.fm.
final class LastFMService: @unchecked Sendable {
    static let shared = LastFMService()
    private init() {}

    // MARK: - Signature

    private func apiSig(params: [String: String], secret: String) -> String {
        let sorted = params.sorted { $0.key < $1.key }
        let concatenated = sorted.map { $0.key + $0.value }.joined() + secret
        let digest = Insecure.MD5.hash(data: Data(concatenated.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func formBody(params: [String: String], secret: String) -> Data? {
        var all = params
        let sig = apiSig(params: all, secret: secret)
        all["api_sig"] = sig
        all["format"] = "json"
        var comps = URLComponents()
        comps.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.percentEncodedQuery?.data(using: .utf8)
    }

    private func makeRequest(params: [String: String]) throws -> URLRequest {
        guard LastFMDefaults.isConfigured else { throw LastFMError.notConfigured }
        guard let url = URL(string: LastFMDefaults.baseUrl) else { throw LastFMError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Trop/1.0 (https://github.com/SwiftyMedia/Trop)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let body = formBody(params: params, secret: LastFMDefaults.secret) else {
            throw LastFMError.invalidResponse
        }
        req.httpBody = body
        return req
    }

    private func perform<T: Decodable>(_ params: [String: String], decode: T.Type) async throws -> T {
        let method = params["method"] ?? "?"
        Log.lastfm.debug("LastFM \(method) params=\(Self.redactedParams(params))")
        let req = try makeRequest(params: params)
        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await HttpClient.data(for: req)
        } catch {
            Log.lastfm.error("LastFM \(method) transport error: \(error.localizedDescription)")
            throw LastFMError.network(error)
        }
        let status = httpResponse.statusCode
        let bodyStr = String(data: data, encoding: .utf8) ?? ""

        // Check for API error embedded in 200 response
        if let errorObj = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data), errorObj.error != 0 {
            // Distinguish unauthorized token (14) for webview flow
            if errorObj.error == 14 {
                throw LastFMError.unauthorizedToken
            }
            Log.lastfm.error("LastFM \(method) apiError=\(errorObj.error) msg=\(errorObj.message)")
            throw LastFMError.api(errorObj.error, errorObj.message)
        }

        if !(200...299).contains(status) {
            // Try to decode error
            if let err = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data) {
                Log.lastfm.error("LastFM \(method) status=\(status) apiError=\(err.error) msg=\(err.message)")
                throw LastFMError.api(err.error, err.message)
            }
            Log.lastfm.error("LastFM \(method) http=\(status) body=\(bodyStr.prefix(300))")
            throw LastFMError.http(status, bodyStr)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Try raw text contains error?
            if bodyStr.contains("\"error\""),
               let err = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data) {
                if err.error == 14 { throw LastFMError.unauthorizedToken }
                Log.lastfm.error("LastFM \(method) apiError=\(err.error) msg=\(err.message)")
                throw LastFMError.api(err.error, err.message)
            }
            Log.lastfm.error("LastFM \(method) decode failed body=\(bodyStr.prefix(300))")
            throw LastFMError.network(error)
        }
    }

    private static let sensitiveParamKeys: Set<String> = ["password", "token", "sk", "api_sig"]

    private static func redactedParams(_ params: [String: String]) -> String {
        params.keys.sorted().map { key in
            sensitiveParamKeys.contains(key) ? "\(key)=<redacted>" : "\(key)=\(params[key] ?? "")"
        }.joined(separator: "&")
    }

    // MARK: - Public API

    func getToken() async throws -> String {
        Log.lastfm.info(
            "auth.getToken configured=\(LastFMDefaults.isConfigured) "
                + "apiKeyLength=\(LastFMDefaults.apiKey.count) "
                + "secretPresent=\(!LastFMDefaults.secret.isEmpty)"
        )
        let params: [String: String] = [
            "method": "auth.getToken",
            "api_key": LastFMDefaults.apiKey
        ]
        let resp: LastFMTokenResponse = try await perform(params, decode: LastFMTokenResponse.self)
        return resp.token
    }

    func getSession(token: String) async throws -> LastFMAuthResponse {
        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": LastFMDefaults.apiKey,
            "token": token
        ]
        return try await perform(params, decode: LastFMAuthResponse.self)
    }

    func updateNowPlaying(artist: String, track: String, album: String?, trackNumber: Int?, duration: Int?) async throws {
        guard let sk = LastFMTokenStore.shared.retrieveSessionKey(), !sk.isEmpty else {
            throw LastFMError.missingSession
        }
        var extra: [String: String] = [
            "artist": artist,
            "track": track,
            "sk": sk
        ]
        if let album, !album.isEmpty { extra["album"] = album }
        if let n = trackNumber { extra["trackNumber"] = String(n) }
        if let d = duration { extra["duration"] = String(d) }
        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "api_key": LastFMDefaults.apiKey
        ]
        for (k, v) in extra { params[k] = v }
        _ = try await perform(params, decode: EmptyResponse.self)
    }

    // swiftlint:disable:next function_parameter_count
    func scrobble(artist: String, track: String, timestamp: Int64, album: String?, trackNumber: Int?, duration: Int?) async throws {
        guard let sk = LastFMTokenStore.shared.retrieveSessionKey(), !sk.isEmpty else {
            throw LastFMError.missingSession
        }
        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": LastFMDefaults.apiKey,
            "sk": sk,
            "artist[0]": artist,
            "track[0]": track,
            "timestamp[0]": String(timestamp)
        ]
        if let album, !album.isEmpty { params["album[0]"] = album }
        if let n = trackNumber { params["trackNumber[0]"] = String(n) }
        if let d = duration { params["duration[0]"] = String(d) }
        _ = try await perform(params, decode: EmptyResponse.self)
    }

    func setLoveStatus(artist: String, track: String, love: Bool) async throws {
        guard let sk = LastFMTokenStore.shared.retrieveSessionKey(), !sk.isEmpty else {
            throw LastFMError.missingSession
        }
        let method = love ? "track.love" : "track.unlove"
        let params: [String: String] = [
            "method": method,
            "api_key": LastFMDefaults.apiKey,
            "sk": sk,
            "artist": artist,
            "track": track
        ]
        _ = try await perform(params, decode: EmptyResponse.self)
    }

    // MARK: - Avatar

    struct UserGetInfoResponse: Decodable {
        let user: LastFMUserDetail
    }

    struct LastFMUserDetail: Decodable {
        let image: [LastFMImage]?
    }

    struct LastFMImage: Decodable {
        let size: String?
        // swiftlint:disable:next identifier_name
        let text: String?
        enum CodingKeys: String, CodingKey {
            case size
            case text = "#text"
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let value = try? single.decode(String.self) {
                size = nil
                text = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            size = try container.decodeIfPresent(String.self, forKey: .size)
            text = try container.decodeIfPresent(String.self, forKey: .text)
        }
    }

    /// Fetches avatar URL via `user.getInfo` (no signature needed). Mirrors Discord's avatar fetch.
    func fetchAvatarURL(username: String) async -> URL? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.lastfm.warning("fetchAvatarURL: empty username")
            return nil
        }
        guard LastFMDefaults.isConfigured else {
            Log.lastfm.warning("fetchAvatarURL: API keys not configured")
            return nil
        }
        var comps = URLComponents(string: LastFMDefaults.baseUrl)
        comps?.queryItems = [
            URLQueryItem(name: "method", value: "user.getInfo"),
            URLQueryItem(name: "user", value: trimmed),
            URLQueryItem(name: "api_key", value: LastFMDefaults.apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = comps?.url else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Trop/1.0 (https://github.com/SwiftyMedia/Trop)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                Log.lastfm.warning("fetchAvatarURL: http=\(status) user=\(trimmed)")
                return nil
            }
            if let err = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data), err.error != 0 {
                Log.lastfm.warning("fetchAvatarURL: apiError=\(err.error) msg=\(err.message)")
                return nil
            }
            let decoded = try JSONDecoder().decode(UserGetInfoResponse.self, from: data)
            let images = decoded.user.image ?? []
            let preference = ["extralarge", "large", "medium", "small"]
            for pref in preference {
                if let match = images.first(where: { $0.size == pref && !($0.text ?? "").isEmpty }) {
                    if let url = Self.validAvatarURL(match.text) { return url }
                }
            }
            if let any = images.first(where: { !($0.text ?? "").isEmpty }) {
                if let url = Self.validAvatarURL(any.text) { return url }
            }
            Log.lastfm.debug("fetchAvatarURL: no image for user=\(trimmed)")
            return nil
        } catch {
            Log.lastfm.warning("fetchAvatarURL failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func validAvatarURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        // Last.fm still returns http URLs in some profiles; the CDN supports
        // HTTPS and ATS otherwise prevents the image request on iOS.
        components.scheme = "https"
        return components.url
    }
}
