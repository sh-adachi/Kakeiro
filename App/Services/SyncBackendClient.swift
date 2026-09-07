import Foundation

struct SyncConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var apiToken: String

    func validatedURL(allowLoopback: Bool = false) throws -> URL {
        guard let url = URL(string: baseURL), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (allowLoopback && url.scheme == "http" && ["127.0.0.1", "localhost"].contains(host)),
              apiToken.count >= 32, apiToken.count <= 4096,
              apiToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw SyncClientError.message("HTTPSのサーバーURLと、32文字以上の接続キーを入力してください。")
        }
        return url
    }
}

struct SyncServiceStatus: Codable, Sendable {
    let revision: Int?
    let configured: Bool
    let connected: Bool
    let isSyncing: Bool
    let lastSuccessfulSync: Date?
    let lastAttemptAt: Date?
    let nextScheduledSync: Date?
    let error: String?
    let warning: String?
    let providerEnvironment: String
    let scheduleTimeZone: String
    let scheduleHour: Int
}

struct MoneytreeConfiguration: Codable, Sendable {
    let clientID: String
    let authorizationURL: String
    let tokenURL: String
    let redirectURI: String
    let scopes: [String]
    let environment: String
}

struct MoneytreeTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let resourceServer: String
}

enum SyncClientError: Error, LocalizedError {
    case message(String)
    case unauthorized
    case noSnapshot
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .unauthorized: return "サーバーの認証に失敗しました。接続キーを確認してください。"
        case .noSnapshot: return "初回のデータ取得がまだ完了していません。しばらくしてから確認してください。"
        }
    }
}

/// Credentials never follow a redirect, and neither requests nor bodies are logged.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class SyncBackendClient {
    private let configuration: SyncConfiguration
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(configuration: SyncConfiguration, allowLoopback: Bool = false) throws {
        self.configuration = configuration
        baseURL = try configuration.validatedURL(allowLoopback: allowLoopback)
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.timeoutIntervalForRequest = 25
        settings.timeoutIntervalForResource = 60
        session = URLSession(configuration: settings, delegate: NoRedirectDelegate(), delegateQueue: nil)
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
    }

    deinit { session.invalidateAndCancel() }

    func status() async throws -> SyncServiceStatus { try decoder.decode(SyncServiceStatus.self, from: await request("v1/status")) }
    func provider() async throws -> MoneytreeConfiguration { try decoder.decode(MoneytreeConfiguration.self, from: await request("v1/provider")) }
    func snapshot() async throws -> SyncSnapshot { try decoder.decode(SyncSnapshot.self, from: await request("v1/snapshot")) }
    func triggerRefresh() async throws { _ = try await request("v1/sync", method: "POST") }
    func connect(_ tokens: MoneytreeTokens) async throws { _ = try await request("v1/connection", method: "POST", body: encoder.encode(tokens)) }
    func disconnect() async throws { _ = try await request("v1/connection", method: "DELETE") }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + configuration.apiToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 128 * 1_024 * 1_024 else { throw SyncClientError.message("サーバーの応答を読み取れません。") }
        if response.statusCode == 401 { throw SyncClientError.unauthorized }
        if response.statusCode == 409 && path == "v1/snapshot" { throw SyncClientError.noSnapshot }
        guard (200..<300).contains(response.statusCode) else {
            // Do not expose arbitrary server response bodies, which may contain credentials.
            if response.statusCode == 429 { throw SyncClientError.message("更新回数の上限に達しています。時間をおいて再度お試しください。") }
            throw SyncClientError.message("サーバーとの処理に失敗しました（HTTP \(response.statusCode)）。連携画面で状態を確認してください。")
        }
        return data
    }
}
